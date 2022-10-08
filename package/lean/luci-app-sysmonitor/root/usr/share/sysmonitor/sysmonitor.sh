#!/bin/bash

if [ "$(ps | grep -v grep | grep sysmonitor.sh | wc -l)" -gt 2 ]; then
	exit 1
fi

sleep_unit=1
NAME=sysmonitor
APP_PATH=/usr/share/$NAME

uci_get_by_name() {
	local ret=$(uci get $1.$2.$3 2>/dev/null)
	echo ${ret:=$4}
}

uci_set_by_name() {
	uci set $1.$2.$3=$4 2>/dev/null
	uci commit $1
}

ping_url() {
	local url=$1
	for i in $( seq 1 3 ); do
		status=$(ping -c 1 -W 1 $url | grep -o 'time=[0-9]*.*' | awk -F '=' '{print$2}'|cut -d ' ' -f 1)
		[ "$status" == "" ] && status=0
		[ "$status" != 0 ] && break
	done
	echo $status
}

check() {
	result=$(curl -s --connect-timeout 1 $1)
	echo $result
}

check_ip() {
	if [ ! -n "$1" ]; then
		#echo "NO IP!"
		echo ""
	else
 		IP=$1
    		VALID_CHECK=$(echo $IP|awk -F. '$1<=255&&$2<=255&&$3<=255&&$4<=255{print "yes"}')
		if echo $IP|grep -E "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$">/dev/null; then
			if [ ${VALID_CHECK:-no} == "yes" ]; then
				# echo "IP $IP available."
				echo $IP
			else
				#echo "IP $IP not available!"
				echo ""
			fi
		else
			#echo "IP is name convert ip!"
			dnsip=$(nslookup $IP|grep Address|sed -n '2,2p'|cut -d' ' -f2)
			if [ ! -n "$dnsip" ]; then
				#echo "Inull"
				echo $test
			else
				#echo "again check"
				echo $(check_ip $dnsip)
			fi
		fi
	fi
}

[ ! $(uci get dhcp.lan.ra) == "relay" ] && touch /tmp/relay
[ ! $(uci get dhcp.lan.ndp) == "relay" ] && touch /tmp/relay
[ ! $(uci get dhcp.lan.dhcpv6) == "relay" ] && touch /tmp/relay
[ -f /tmp/relay ] && {
	uci set dhcp.lan.ra='relay'
	uci set dhcp.lan.dhcpv6='relay'
	uci set dhcp.lan.ndp='relay'
	uci commit dhcp
	/etc/init.d/odhcpd restart &
	rm /tmp/relay
}

sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
gateway=$(uci get network.wan.gateway)
d=$(date "+%Y-%m-%d %H:%M:%S")
echo $d": Sysmonitor is up." >> /var/log/sysmonitor.log
echo $d": gateway="$gateway >> /var/log/sysmonitor.log

while [ "1" == "1" ]; do #死循环
	ifname=$(uci get network.wan6.ifname)
	ipv6=$(ip -o -6 addr list $ifname|cut -d ' ' -f7)
	cat /www/ip6.html | grep $(echo $ipv6|cut -d'/' -f1 |head -n1) > /dev/null
	[  $? -ne 0 ] && {
		d=$(date "+%Y-%m-%d %H:%M:%S")
		echo $d": IP6: "$ipv6 >> /var/log/sysmonitor.log
		echo $ipv6|cut -d'/' -f1|head -n1 >/www/ip6.html
		# ip6 changed,samba4 mast rebind ip6 
		#[ -f /etc/init.d/samba4 ] && /etc/init.d/samba4 restart
	}
	homeip=$(uci_get_by_name $NAME sysmonitor homeip 0)
	vpnip=$(uci_get_by_name $NAME sysmonitor vpnip 0)
	gateway=$(check_ip $(uci get network.wan.gateway))
	if [ "$vpnip" == "192.168.1.110" ]; then
		url=$vpnip"/ip.html"
	else
		url=$vpnip":8080/ip.html"
	fi
	runssr=0
	[ -f "/etc/init.d/shadowsocksr" ] && runssr=$(ps |grep ssrplus/bin/ssr-|grep -v grep |wc -l)
	if [ "$runssr" == 0 ];then
		[ -f "/etc/init.d/passwall" ] && runssr=$(ps |grep /etc/passwall |grep -v grep |wc -l)
	fi
	if [ "$runssr" -gt 0 ]; then
		vpnok=0
		if [ $gateway == $vpnip ]; then	
			d=$(date "+%Y-%m-%d %H:%M:%S")
			echo $d": gateway="$homeip "(Local VPN)" >> /var/log/sysmonitor.log
			uci set network.wan.gateway=$homeip
			sed -i '/list dns/d' /etc/config/network
			uci add_list network.wan.dns=$homeip
			uci commit network
			uci set dhcp.@dnsmasq[0].rebind_localhost='1'
			uci set dhcp.@dnsmasq[0].rebind_protection='1'
			uci commit dhcp
			ifup wan
			ifup wan6
			/etc/init.d/odhcpd restart
		fi
	else
		status=$(check $url)
		if [ ! -n "$status" ]; then
			vpnok=0
			if [ $gateway == $vpnip ]; then
				d=$(date "+%Y-%m-%d %H:%M:%S")
				echo $d": gateway="$homeip >> /var/log/sysmonitor.log
				uci set network.wan.gateway=$homeip
				uci del network.wan.dns
				uci add_list network.wan.dns='119.29.29.29'
				uci add_list network.wan.dns='223.5.5.5'
				uci add_list network.wan.dns='114.114.114.114'
				uci commit network
				uci set dhcp.@dnsmasq[0].rebind_localhost='1'
				uci set dhcp.@dnsmasq[0].rebind_protection='1'
				uci commit dhcp
				ifup wan
				ifup wan6
				/etc/init.d/odhcpd restart
			fi
		else
			vpnok=1
			if [ ! $gateway == $vpnip ]; then
				d=$(date "+%Y-%m-%d %H:%M:%S")
				echo $d": VPN-gateway="$vpnip >> /var/log/sysmonitor.log
				uci set network.wan.gateway=$vpnip
				uci del network.wan.dns
				uci add_list network.wan.dns=$vpnip
				uci commit network
				uci set dhcp.@dnsmasq[0].rebind_localhost='0'
				uci set dhcp.@dnsmasq[0].rebind_protection='0'
				uci commit dhcp
				ifup wan
				ifup wan6
				$APP_PATH/sysapp.sh set_smartdns
				/etc/init.d/odhcpd restart
			fi
		fi
	fi

	num=0
	while [ $num -le 10 ]; do
		sleep $sleep_unit
		if [ $(uci_get_by_name $NAME sysmonitor enable 0) == 0 ]; then
			d=$(date "+%Y-%m-%d %H:%M:%S")
			echo $d": gateway="$homeip >> /var/log/sysmonitor.log
			echo $d": Sysmonitor is down." >> /var/log/sysmonitor.log
			uci set network.wan.gateway=$homeip
#			sed -i '/list dns/d' /etc/config/network
			uci del network.wan.dns
			uci add_list network.wan.dns='119.29.29.29'
			uci add_list network.wan.dns='223.5.5.5'
			uci add_list network.wan.dns='114.114.114.114'
			uci commit network
			uci set dhcp.@dnsmasq[0].rebind_localhost='1'
			uci set dhcp.@dnsmasq[0].rebind_protection='1'
			uci commit dhcp
			ifup wan
			ifup wan6
			/etc/init.d/odhcpd restart		
			exit 0
		fi
		let num=num+sleep_unit
		runssr=0
		[ -f "/etc/init.d/shadowsocksr" ] && runssr=$(ps |grep ssrplus/bin/ssr-|grep -v grep |wc -l)
		if [ "$runssr" == 0 ]; then 
			[ -f "/etc/init.d/passwall" ] && runssr=$(ps |grep /etc/passwall |grep -v grep |wc -l)
		fi
		gateway=$(route |grep default|sed 's/default[[:space:]]*//'|sed 's/[[:space:]].*$//')
		if [ "$runssr" == 0 ]; then
			if [ "$vpnok" == 1 ]; then
				[ $gateway == $homeip ] && num=50
			fi
		else
			[ $gateway == $vpnip ] && num=50
		fi
		if [ -f "/tmp/sysmonitor" ]; then
			rm /tmp/sysmonitor
			num=50
		fi
	done
done

