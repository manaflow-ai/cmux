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
    tracing::info!(port = hub.port(), advertised = mdns.is_some(), "local link hub up");
    Some(LocalLink { hub, serve, mdns })
}

/// Advertise `ad` on every interface for the hub at `port`.
fn advertise(ad: &LocalAd, port: u16) -> Option<mdns_sd::ServiceDaemon> {
    let daemon = mdns_sd::ServiceDaemon::new().map_err(|e| tracing::warn!(%e, "mDNS not started")).ok()?;
    let short: String = ad.device_id.chars().filter(char::is_ascii_alphanumeric).take(12).collect();
    let instance = format!("cmux-{short}");
    let host = format!("{instance}.local.");
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
}
