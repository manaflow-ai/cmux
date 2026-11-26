//! Nearby links with no internet (ultra-connectivity P7): this Mac's local
//! hub (`cmux_mobile_link::local_hub`), answered by the same
//! `serve_signaling` as the Worker's socket, and its Bonjour ad
//! (`_cmux-link._tcp`, TXT `id`, `v`, `k`: no secret).
//!
//! It runs beside the Worker loop, not inside it: a Mac with no route out
//! cannot get a token or register, and still answers a phone beside it.
//! Answers here use no ICE servers, so no STUN and no DNS: the phone found
//! this Mac on the link, and the host addresses are the path.
//!
//! On by default under the app (supervised: only devices on the pairing's
//! trust list may signal, and the `auth` channel still proves them).
//! `CMUX_MOBILE_LOCAL_LINK=0` turns it off; `=1` turns it on for an
//! unsupervised hostd (netlab), which admits any device id, as an
//! unsupervised link serves without auth anyway.
//!
//! Beside mdns-sd's responder, [`answer_qu`] answers NWBrowser's first
//! question (QU, from port 5353) by unicast at once: mdns-sd answers it by
//! multicast after a shared-record delay, or not at all within its
//! once-per-second rate limit (`cmux_mobile_link::local_dns`).

use std::net::{IpAddr, Ipv6Addr, SocketAddr, SocketAddrV6};
use std::sync::Arc;
use std::time::Duration;

use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::local::{self, AD_VERSION, LOCAL_USER, LocalAd, SERVICE_TYPE};
use cmux_mobile_link::local_dns;
use cmux_mobile_link::local_hub::{Admit, LocalHub};

use crate::config::{HostConfig, ServiceConfig};
use crate::host::{AnswerContext, IceSource, serve_signaling};

/// The running hub, its answer loop and its ad; dropping it stops all three.
pub struct LocalLink {
    hub: LocalHub,
    serve: tokio::task::JoinHandle<()>,
    mdns: Option<mdns_sd::ServiceDaemon>,
    _qu: Option<AbortOnDrop>,
}

impl Drop for LocalLink {
    fn drop(&mut self) {
        self.serve.abort();
        if let Some(daemon) = self.mdns.take() {
            let _ = daemon.shutdown();
        }
    }
}

impl LocalLink {
    pub fn port(&self) -> u16 {
        self.hub.port()
    }
}

/// Whether this hostd runs a local hub: `CMUX_MOBILE_LOCAL_LINK` when set,
/// else when supervised.
pub fn enabled(supervised: bool) -> bool {
    match std::env::var("CMUX_MOBILE_LOCAL_LINK").ok().as_deref().map(str::trim) {
        Some("0" | "false" | "off") => false,
        Some("1" | "true" | "on") => true,
        _ => supervised,
    }
}

/// Start the hub, its answer loop and its ad, when [`enabled`].
pub async fn start(
    config: &HostConfig,
    services: &Arc<ServiceConfig>,
    mailbox: &Option<Arc<crate::mailbox::Mailbox>>,
) -> Option<LocalLink> {
    if !enabled(services.pairing.is_some()) {
        return None;
    }
    let admit: Admit = match services.pairing.as_ref() {
        Some(pairing) => {
            let trust = pairing.trust.clone();
            Arc::new(move |device: &str| {
                trust.borrow().as_ref().is_some_and(|t| t.devices.iter().any(|d| d.id == device))
            })
        }
        None => Arc::new(|_: &str| true),
    };
    let port = std::env::var("CMUX_MOBILE_LOCAL_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(0);
    // Both families on one socket where the OS allows (AWDL is IPv6 link-local only).
    let any6 = SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, port, 0, 0));
    let hub = match LocalHub::bind(any6, &config.device_id, Arc::clone(&admit)).await {
        Ok(hub) => hub,
        Err(_) => {
            match LocalHub::bind(SocketAddr::from(([0, 0, 0, 0], port)), &config.device_id, admit).await {
                Ok(hub) => hub,
                Err(error) => {
                    tracing::warn!(%error, "local link hub not started");
                    return None;
                }
            }
        }
    };
    let context = AnswerContext {
        owner_user_id: LOCAL_USER.to_owned(),
        services: Arc::clone(services),
        ice: IceSource::Fixed(Vec::new()),
        include_loopback: config.include_loopback,
        exclude_cgnat: config.exclude_cgnat,
        mailbox: mailbox.clone(),
        session_exposure: config.session_exposure.clone(),
    };
    let (url, secret, device) = (hub.loopback_url(), hub.secret().to_owned(), config.device_id.clone());
    let serve = tokio::spawn(async move {
        loop {
            match SignalingClient::connect_local(&url, &secret, &device).await {
                Ok(signaling) => {
                    // Local sessions of a previous hub socket send on this one now.
                    cmux_mobile_link::dial::wireguard::rehome(&signaling);
                    let reason = serve_signaling(signaling, context.clone()).await;
                    tracing::debug!(reason, "local hub socket ended");
                }
                Err(error) => tracing::warn!(%error, "local hub socket not opened"),
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    });
    // The identity as of now; a Mac paired later advertises without a tag
    // until its next start, and a phone then matches on the id alone.
    let tag = services.pairing.as_ref().and_then(|p| {
        p.identity.borrow().as_ref().map(|identity| local::key_tag(identity.public_key().as_bytes()))
    });
    let ad = LocalAd { device_id: config.device_id.clone(), version: AD_VERSION, tag };
    let mdns = advertise(&ad, hub.port());
    let qu = mdns.as_ref().and_then(|_| answer_qu(&ad, hub.port()));
    tracing::info!(port = hub.port(), advertised = mdns.is_some(), qu = qu.is_some(), "local link hub up");
    Some(LocalLink { hub, serve, mdns, _qu: qu })
}

/// The ad's instance and host names (`cmux-<id>`, `cmux-<id>.local.`).
fn ad_names(ad: &LocalAd) -> (String, String) {
    let short: String = ad.device_id.chars().filter(char::is_ascii_alphanumeric).take(12).collect();
    let instance = format!("cmux-{short}");
    let host = format!("{instance}.local.");
    (instance, host)
}

/// Advertise `ad` on every interface for the hub at `port`.
fn advertise(ad: &LocalAd, port: u16) -> Option<mdns_sd::ServiceDaemon> {
    let daemon = mdns_sd::ServiceDaemon::new().map_err(|e| tracing::warn!(%e, "mDNS not started")).ok()?;
    let (instance, host) = ad_names(ad);
    let txt: Vec<(String, String)> = ad.txt();
    let info = mdns_sd::ServiceInfo::new(SERVICE_TYPE, &instance, &host, "", port, &txt[..])
        .map_err(|e| tracing::warn!(%e, "mDNS ad not built"))
        .ok()?
        .enable_addr_auto();
    daemon.register(info).map_err(|e| tracing::warn!(%e, "mDNS ad not registered")).ok()?;
    Some(daemon)
}

/// Browse for Mac `mac`'s hub (and `tag`, when known) for up to `wait`:
/// its addresses, best first. The desktop's browse (the dial tool, and a Mac
/// dialing a Mac); iOS browses with NWBrowser and feeds the same policy.
///
/// Two askers race: a one-shot query from an ephemeral port
/// (`cmux_mobile_link::local_dns`), which a responder answers by unicast at
/// once, and a full mDNS browse, for responders that answer only multicast.
pub async fn browse(mac: &str, tag: Option<&str>, wait: Duration) -> Vec<SocketAddr> {
    let found = tokio::time::timeout(wait, async {
        tokio::select! {
            found = one_shot(mac, tag) => found,
            found = full_browse(mac, tag) => found,
        }
    })
    .await;
    found.unwrap_or_default()
}

fn socket_addresses(ips: impl IntoIterator<Item = SocketAddr>) -> Vec<SocketAddr> {
    let addresses: Vec<SocketAddr> =
        ips.into_iter().filter(|a| !matches!(a.ip(), IpAddr::V4(ip) if ip.is_unspecified())).collect();
    local::ordered(addresses)
}

/// Ask on every interface every [`ONE_SHOT_RESEND`] until a matching answer.
/// Never returns empty-handed (the caller's timeout ends it).
async fn one_shot(mac: &str, tag: Option<&str>) -> Vec<SocketAddr> {
    let sockets = one_shot_sockets();
    if sockets.is_empty() {
        return std::future::pending().await;
    }
    let id = uuid::Uuid::new_v4();
    let packet = local_dns::query(u16::from_be_bytes([id.as_bytes()[0], id.as_bytes()[1]]));
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(Vec<u8>, SocketAddr)>();
    let mut tasks = Vec::new();
    for (socket, _) in &sockets {
        let (socket, tx) = (Arc::clone(socket), tx.clone());
        tasks.push(AbortOnDrop(tokio::spawn(async move {
            let mut buffer = vec![0u8; 9000];
            while let Ok((n, from)) = socket.recv_from(&mut buffer).await {
                if tx.send((buffer[..n].to_vec(), from)).is_err() {
                    break;
                }
            }
        })));
    }
    let mut resend = tokio::time::interval(ONE_SHOT_RESEND);
    loop {
        tokio::select! {
            _ = resend.tick() => {
                for (socket, group) in &sockets {
                    let _ = socket.send_to(&packet, group).await;
                }
            }
            Some((reply, from)) = rx.recv() => {
                for found in local_dns::parse(&reply) {
                    let Some(ad) = LocalAd::from_txt(found.txt.iter().map(|(k, v)| (k.as_str(), v.as_str()))) else {
                        continue;
                    };
                    if !ad.matches(mac, tag) {
                        continue;
                    }
                    // A link-local address is only good on the interface it came in on.
                    let scope = match from { SocketAddr::V6(v6) => v6.scope_id(), SocketAddr::V4(_) => 0 };
                    let addresses = socket_addresses(found.addresses.iter().map(|ip| match ip {
                        IpAddr::V6(v6) => SocketAddr::V6(SocketAddrV6::new(
                            *v6, found.port, 0, if v6.is_unicast_link_local() { scope } else { 0 })),
                        v4 => SocketAddr::new(*v4, found.port),
                    }));
                    if !addresses.is_empty() {
                        tracing::debug!(?from, ?addresses, "local hub found by one-shot query");
                        return addresses;
                    }
                }
            }
        }
    }
}

const ONE_SHOT_RESEND: Duration = Duration::from_millis(150);

struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// One ephemeral UDP socket per up, non-loopback interface address family,
/// pinned to that interface for multicast, with the group to send to.
fn one_shot_sockets() -> Vec<(Arc<tokio::net::UdpSocket>, SocketAddr)> {
    use socket2::{Domain, Protocol, Socket, Type};
    let mut out = Vec::new();
    let mut seen_v6 = std::collections::HashSet::new();
    for network in cmux_transport::local_networks() {
        if network.address.is_loopback() {
            continue;
        }
        let made = (|| -> std::io::Result<(Socket, SocketAddr)> {
            match network.address {
                IpAddr::V4(v4) => {
                    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
                    socket.set_multicast_if_v4(&v4)?;
                    socket.set_multicast_ttl_v4(255)?;
                    socket.bind(&SocketAddr::from((v4, 0)).into())?;
                    Ok((socket, SocketAddr::from((local_dns::MDNS_V4, local_dns::MDNS_PORT))))
                }
                IpAddr::V6(_) => {
                    let name =
                        std::ffi::CString::new(network.interface.clone()).map_err(std::io::Error::other)?;
                    // SAFETY: a NUL-terminated name, read only.
                    let index = unsafe { libc::if_nametoindex(name.as_ptr()) };
                    if index == 0 || !seen_v6.insert(index) {
                        return Err(std::io::Error::other("skip"));
                    }
                    let socket = Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP))?;
                    socket.set_only_v6(true)?;
                    socket.set_multicast_if_v6(index)?;
                    socket.set_multicast_hops_v6(255)?;
                    socket.bind(&SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0)).into())?;
                    Ok((
                        socket,
                        SocketAddr::V6(SocketAddrV6::new(local_dns::MDNS_V6, local_dns::MDNS_PORT, 0, index)),
                    ))
                }
            }
        })();
        let Ok((socket, group)) = made else { continue };
        if socket.set_nonblocking(true).is_err() {
            continue;
        }
        if let Ok(socket) = tokio::net::UdpSocket::from_std(socket.into()) {
            out.push((Arc::new(socket), group));
        }
    }
    out
}

/// Answer QU questions for [`SERVICE_TYPE`] (NWBrowser's first question,
/// from port 5353) with `ad`'s full record set by unicast, at once, from
/// port 5353 (RFC 6762 §5.4, §6), beside mdns-sd, whose multicast answer
/// to it waits out a shared-record delay and its one-second rate limit.
/// Questions from other ports are mdns-sd's (it answers those unicast at
/// once already), as are QM questions. `None` when neither family's socket
/// opened: the ad still works, only slower to a first NWBrowser question.
fn answer_qu(ad: &LocalAd, port: u16) -> Option<AbortOnDrop> {
    let (instance, host) = ad_names(ad);
    let txt = ad.txt();
    let sockets: Vec<Arc<tokio::net::UdpSocket>> =
        [qu_socket_v4(), qu_socket_v6()].into_iter().flatten().map(Arc::new).collect();
    if sockets.is_empty() {
        tracing::debug!("no QU answer socket on port 5353");
        return None;
    }
    let task = tokio::spawn(async move {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(usize, Vec<u8>, SocketAddr)>();
        let mut readers = Vec::new();
        for (index, socket) in sockets.iter().enumerate() {
            let (socket, tx) = (Arc::clone(socket), tx.clone());
            readers.push(AbortOnDrop(tokio::spawn(async move {
                let mut buffer = vec![0u8; 9000];
                while let Ok((n, from)) = socket.recv_from(&mut buffer).await {
                    if tx.send((index, buffer[..n].to_vec(), from)).is_err() {
                        break;
                    }
                }
            })));
        }
        drop(tx);
        while let Some((index, packet, from)) = rx.recv().await {
            if from.port() != local_dns::MDNS_PORT || !local_dns::asks_unicast(&packet) {
                continue;
            }
            let addresses = reply_addresses(&cmux_transport::local_networks(), from, interface_index);
            if addresses.is_empty() {
                continue;
            }
            let reply = local_dns::answer(&instance, &host, port, &txt, &addresses);
            let sent = sockets[index].send_to(&reply, from).await;
            tracing::debug!(?from, ?addresses, ok = sent.is_ok(), "answered a QU question");
        }
    });
    Some(AbortOnDrop(task))
}

/// The addresses to answer `from`'s question with: this host's addresses of
/// `from`'s family on the interface it asked on (its IPv6 scope, else the
/// subnet that holds it), else every non-loopback one of that family.
fn reply_addresses(
    networks: &[cmux_transport::LocalNetwork],
    from: SocketAddr,
    index_of: impl Fn(&str) -> u32,
) -> Vec<IpAddr> {
    let family: Vec<&cmux_transport::LocalNetwork> = networks
        .iter()
        .filter(|n| {
            n.address.is_ipv4() == from.is_ipv4() && !n.address.is_loopback() && !n.address.is_unspecified()
        })
        .collect();
    let interface = match from {
        SocketAddr::V6(v6) if v6.scope_id() != 0 => {
            family.iter().find(|n| index_of(&n.interface) == v6.scope_id()).map(|n| n.interface.clone())
        }
        _ => family.iter().find(|n| same_subnet(n.address, n.prefix, from.ip())).map(|n| n.interface.clone()),
    };
    let chosen: Vec<IpAddr> = family
        .iter()
        .filter(|n| interface.as_ref().is_none_or(|i| *i == n.interface))
        .map(|n| n.address)
        .collect();
    let mut out = Vec::new();
    for address in chosen {
        if !out.contains(&address) {
            out.push(address);
        }
    }
    out
}

fn same_subnet(network: IpAddr, prefix: u8, ip: IpAddr) -> bool {
    match (network, ip) {
        (IpAddr::V4(n), IpAddr::V4(ip)) => {
            let mask = u32::MAX.checked_shl(32 - u32::from(prefix.min(32))).unwrap_or(0);
            u32::from(n) & mask == u32::from(ip) & mask
        }
        (IpAddr::V6(n), IpAddr::V6(ip)) => {
            let mask = u128::MAX.checked_shl(128 - u32::from(prefix.min(128))).unwrap_or(0);
            u128::from(n) & mask == u128::from(ip) & mask
        }
        _ => false,
    }
}

fn interface_index(name: &str) -> u32 {
    let Ok(name) = std::ffi::CString::new(name) else { return 0 };
    // SAFETY: a NUL-terminated name, read only.
    unsafe { libc::if_nametoindex(name.as_ptr()) }
}

/// A port-5353 socket shared with the platform's responder and mdns-sd
/// (SO_REUSEADDR and SO_REUSEPORT), in the mDNS group on every up IPv4
/// interface, replies at TTL 255 (RFC 6762 §11).
fn qu_socket_v4() -> Option<tokio::net::UdpSocket> {
    use socket2::{Domain, Protocol, Socket, Type};
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP)).ok()?;
    socket.set_reuse_address(true).ok()?;
    #[cfg(unix)]
    socket.set_reuse_port(true).ok()?;
    socket.set_ttl_v4(255).ok()?;
    socket.set_multicast_ttl_v4(255).ok()?;
    socket.bind(&SocketAddr::from(([0, 0, 0, 0], local_dns::MDNS_PORT)).into()).ok()?;
    let mut joined = false;
    for network in cmux_transport::local_networks() {
        if let IpAddr::V4(v4) = network.address
            && !v4.is_loopback()
        {
            joined |= socket.join_multicast_v4(&local_dns::MDNS_V4, &v4).is_ok();
        }
    }
    socket.set_nonblocking(true).ok()?;
    joined.then(|| tokio::net::UdpSocket::from_std(socket.into()).ok()).flatten()
}

/// [`qu_socket_v4`]'s IPv6 twin (AWDL is IPv6 link-local only).
fn qu_socket_v6() -> Option<tokio::net::UdpSocket> {
    use socket2::{Domain, Protocol, Socket, Type};
    let socket = Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP)).ok()?;
    socket.set_only_v6(true).ok()?;
    socket.set_reuse_address(true).ok()?;
    #[cfg(unix)]
    socket.set_reuse_port(true).ok()?;
    socket.set_unicast_hops_v6(255).ok()?;
    socket.set_multicast_hops_v6(255).ok()?;
    socket
        .bind(&SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, local_dns::MDNS_PORT, 0, 0)).into())
        .ok()?;
    let mut joined = std::collections::HashSet::new();
    for network in cmux_transport::local_networks() {
        if network.address.is_ipv6() && !network.address.is_loopback() {
            let index = interface_index(&network.interface);
            if index != 0
                && !joined.contains(&index)
                && socket.join_multicast_v6(&local_dns::MDNS_V6, index).is_ok()
            {
                joined.insert(index);
            }
        }
    }
    socket.set_nonblocking(true).ok()?;
    (!joined.is_empty()).then(|| tokio::net::UdpSocket::from_std(socket.into()).ok()).flatten()
}

/// mdns-sd's browse: the first matching resolved ad. Never returns
/// empty-handed (the caller's timeout ends it).
async fn full_browse(mac: &str, tag: Option<&str>) -> Vec<SocketAddr> {
    let Ok(daemon) = mdns_sd::ServiceDaemon::new() else { return std::future::pending().await };
    struct Shutdown(mdns_sd::ServiceDaemon);
    impl Drop for Shutdown {
        fn drop(&mut self) {
            let _ = self.0.shutdown();
        }
    }
    let daemon = Shutdown(daemon);
    let Ok(events) = daemon.0.browse(SERVICE_TYPE) else { return std::future::pending().await };
    while let Ok(event) = events.recv_async().await {
        let mdns_sd::ServiceEvent::ServiceResolved(service) = event else { continue };
        let txt = service.txt_properties.iter().map(|p| (p.key(), p.val_str()));
        let Some(ad) = LocalAd::from_txt(txt) else { continue };
        if !ad.matches(mac, tag) {
            continue;
        }
        let addresses = socket_addresses(service.addresses.iter().map(|ip| match ip {
            mdns_sd::ScopedIp::V6(v6) => SocketAddr::V6(SocketAddrV6::new(
                *v6.addr(),
                service.port,
                0,
                if v6.addr().is_unicast_link_local() { v6.scope_id().index } else { 0 },
            )),
            other => SocketAddr::new(other.to_ip_addr(), service.port),
        }));
        if !addresses.is_empty() {
            tracing::debug!(?addresses, "local hub found by mDNS browse");
            return addresses;
        }
    }
    std::future::pending().await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn env_overrides_supervision() {
        // Read-only on the process env: only the default path is checked here.
        if std::env::var_os("CMUX_MOBILE_LOCAL_LINK").is_none() {
            assert!(enabled(true));
            assert!(!enabled(false));
        }
    }

    #[test]
    fn qu_answers_carry_the_askers_interface_addresses() {
        let net = |interface: &str, address: &str, prefix| cmux_transport::LocalNetwork {
            interface: interface.into(),
            address: address.parse().unwrap(),
            prefix,
        };
        let networks = [
            net("lo", "127.0.0.1", 8),
            net("en0", "192.168.1.20", 24),
            net("en1", "10.0.0.5", 8),
            net("en0", "fe80::1", 64),
            net("awdl0", "fe80::2", 64),
        ];
        let index = |name: &str| match name {
            "en0" => 4,
            "awdl0" => 9,
            _ => 0,
        };
        let from = |s: &str| s.parse::<SocketAddr>().unwrap();
        let ips = |list: &[&str]| list.iter().map(|s| s.parse::<IpAddr>().unwrap()).collect::<Vec<_>>();
        assert_eq!(reply_addresses(&networks, from("192.168.1.7:5353"), index), ips(&["192.168.1.20"]));
        assert_eq!(reply_addresses(&networks, from("10.9.9.9:5353"), index), ips(&["10.0.0.5"]));
        assert_eq!(
            reply_addresses(&networks, from("172.16.0.1:5353"), index),
            ips(&["192.168.1.20", "10.0.0.5"]),
            "no subnet holds it: every non-loopback IPv4 address"
        );
        assert_eq!(reply_addresses(&networks, from("[fe80::77%9]:5353"), index), ips(&["fe80::2"]));
        assert_eq!(reply_addresses(&networks, from("[fe80::77%4]:5353"), index), ips(&["fe80::1"]));
    }

    /// 13e: NWBrowser's first question is QU, from port 5353, so mdns-sd
    /// answers it by multicast after its shared-record delay, and drops the
    /// answer when it multicast the record within the last second (its
    /// announcements, another browser's answer); the phone then waits for
    /// its next question, ~1 s later. This emulates the phone (a QU PTR
    /// question at once, QM at 1 s and 3 s, as mDNSResponder spaces them;
    /// unicast replies on its own `<ip>:5353`, multicast on the group) and
    /// times browse start to the first packet carrying the ad, with mdns-sd
    /// alone and with [`answer_qu`] beside it, 200 ms after the ad went up
    /// (inside its announcements) and at steady state. Skips without a
    /// multicast-capable IPv4 interface.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn nwbrowser_qu_question_first_ad_ms() {
        let Some(ip) = cmux_transport::local_networks().into_iter().find_map(|n| match n.address {
            IpAddr::V4(v4) if !v4.is_loopback() && phone_sockets(v4).is_some() => Some(v4),
            _ => None,
        }) else {
            eprintln!("skipped: no multicast-capable IPv4 interface");
            return;
        };
        let mut results = Vec::new();
        for (round, (with_qu, settle)) in
            [(false, 200), (true, 200), (false, 3000), (true, 3000)].into_iter().enumerate()
        {
            let ad = LocalAd {
                device_id: format!(
                    "qu{round}{:x}{}",
                    std::process::id(),
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .subsec_nanos()
                ),
                version: AD_VERSION,
                tag: None,
            };
            let Some(mdns) = advertise(&ad, 40000 + round as u16) else {
                eprintln!("skipped: mDNS daemon did not start");
                return;
            };
            let qu = if with_qu { answer_qu(&ad, 40000 + round as u16) } else { None };
            if with_qu && qu.is_none() {
                eprintln!("skipped: no QU answer socket");
                return;
            }
            tokio::time::sleep(Duration::from_millis(settle)).await;
            let (instance, _) = ad_names(&ad);
            let ms = first_ad_ms(ip, &instance).await;
            let _ = mdns.shutdown();
            drop(qu);
            eprintln!("13e first ad: qu-answer={with_qu} settle={settle}ms -> {ms:?} ms");
            results.push((with_qu, settle, ms));
        }
        for (with_qu, settle, ms) in results {
            if with_qu {
                let ms = ms.unwrap_or_else(|| panic!("no ad with the QU answer (settle {settle} ms)"));
                assert!(ms < 500, "the QU answer took {ms} ms (settle {settle} ms)");
            }
        }
    }

    /// The phone's two sockets: `<ip>:5353` (its unicast replies) and the
    /// group on `ip` (multicast ones), both shared on port 5353.
    fn phone_sockets(ip: std::net::Ipv4Addr) -> Option<(tokio::net::UdpSocket, tokio::net::UdpSocket)> {
        use socket2::{Domain, Protocol, Socket, Type};
        let shared = |bind: std::net::Ipv4Addr| -> Option<Socket> {
            let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP)).ok()?;
            socket.set_reuse_address(true).ok()?;
            socket.set_reuse_port(true).ok()?;
            socket.bind(&SocketAddr::from((bind, local_dns::MDNS_PORT)).into()).ok()?;
            socket.set_nonblocking(true).ok()?;
            Some(socket)
        };
        let unicast = shared(ip)?;
        unicast.set_multicast_if_v4(&ip).ok()?;
        unicast.set_multicast_loop_v4(true).ok()?;
        unicast.set_multicast_ttl_v4(255).ok()?;
        let group = shared(local_dns::MDNS_V4)?;
        group.join_multicast_v4(&local_dns::MDNS_V4, &ip).ok()?;
        Some((
            tokio::net::UdpSocket::from_std(unicast.into()).ok()?,
            tokio::net::UdpSocket::from_std(group.into()).ok()?,
        ))
    }

    async fn first_ad_ms(ip: std::net::Ipv4Addr, instance: &str) -> Option<u128> {
        let (unicast, group) = phone_sockets(ip)?;
        let to = SocketAddr::from((local_dns::MDNS_V4, local_dns::MDNS_PORT));
        let start = std::time::Instant::now();
        let ask = async {
            unicast.send_to(&local_dns::query_with(0, true), to).await.ok()?;
            for at in [1000, 3000] {
                tokio::time::sleep_until(tokio::time::Instant::from_std(start + Duration::from_millis(at)))
                    .await;
                unicast.send_to(&local_dns::query_with(0, false), to).await.ok()?;
            }
            std::future::pending::<Option<()>>().await
        };
        let hear = async {
            let (mut a, mut b) = (vec![0u8; 9000], vec![0u8; 9000]);
            loop {
                let packet = tokio::select! {
                    Ok((n, _)) = unicast.recv_from(&mut a) => a[..n].to_vec(),
                    Ok((n, _)) = group.recv_from(&mut b) => b[..n].to_vec(),
                };
                if local_dns::parse(&packet).iter().any(|f| f.instance.starts_with(instance)) {
                    return start.elapsed().as_millis();
                }
            }
        };
        tokio::time::timeout(Duration::from_secs(5), async {
            tokio::select! {
                ms = hear => Some(ms),
                _ = ask => None,
            }
        })
        .await
        .ok()
        .flatten()
    }
}
