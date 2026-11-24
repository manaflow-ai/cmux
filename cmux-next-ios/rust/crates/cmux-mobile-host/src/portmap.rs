//! NAT port mapping for the Mac's WireGuard sockets (P9; PROTOCOL.md "Mapped
//! endpoints"): ask the home router for a public UDP port that forwards to a
//! session's socket, with PCP (RFC 6887), else NAT-PMP (RFC 6886), else
//! UPnP-IGD, and hand the mapped address to the link, which offers it to the
//! phone as an endpoint labeled `mapped`. A phone behind a NAT that maps per
//! destination (symmetric NAT, a carrier's CGNAT) reaches a mapped port
//! directly, where hole punching alone ends on TURN.
//!
//! - Never on the link's critical path: the link asks after `wg-resp`, in the
//!   background ([`cmux_mobile_link::dial::portmap`]), and the protocol the
//!   router answered is cached per gateway, so the next session asks it first
//!   (and a router that maps nothing is not asked again until the gateway or
//!   this Mac's address changes).
//! - Each mapping is renewed at half its lifetime and deleted when its
//!   session ends or roams (the roam maps its new socket), and every live one
//!   at exit ([`release_all`]).
//! - `CMUX_MOBILE_PORTMAP=0` turns it off ([`enabled`]).
//!
//! The router is this Mac's default IPv4 gateway ([`default_gateway`]). A
//! mapped address that is not public (a router behind another NAT, CGNAT
//! 100.64/10) is not offered: the phone could not reach it.
//!
//! n0's `portmapper` crate does the same for iroh, but it maps one port per
//! client and pulls in hyper, netwatch and iroh-metrics; this is the part
//! the Mac needs, on tokio alone.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use cmux_mobile_link::dial::portmap::{MapFuture, PortMapper, PortMapping};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};
use tokio::sync::watch;

/// PCP's and NAT-PMP's server port on the gateway.
pub const PMP_PORT: u16 = 5351;
/// The SSDP multicast group and port UPnP devices answer on.
pub const SSDP: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(239, 255, 255, 250)), 1900);
/// The lifetime asked for (PCP, NAT-PMP, UPnP); renewed at half of what the
/// router grants.
const LIFETIME_S: u32 = 3600;
/// Each PCP or NAT-PMP request is sent this many times, waiting this long
/// for the answer after each (RFC 6886 starts at 250 ms; the full doubling
/// to 64 s is far too long for a router that does not speak it).
const UDP_TRIES: [Duration; 2] = [Duration::from_millis(250), Duration::from_millis(500)];
/// How long SSDP answers are awaited.
const SSDP_WAIT: Duration = Duration::from_millis(1200);
/// One IGD HTTP exchange.
const HTTP_WAIT: Duration = Duration::from_secs(2);
/// The most of an IGD HTTP answer read.
const HTTP_MAX: usize = 64 * 1024;
/// Waits before a failed renewal is tried again.
const RENEW_RETRIES: [Duration; 4] =
    [Duration::from_secs(5), Duration::from_secs(15), Duration::from_secs(60), Duration::from_secs(300)];

/// Whether this process maps ports: unless `CMUX_MOBILE_PORTMAP=0`.
pub fn enabled() -> bool {
    enabled_by(std::env::var("CMUX_MOBILE_PORTMAP").ok().as_deref())
}

/// The kill switch's parse: on unless the value is `0`.
fn enabled_by(value: Option<&str>) -> bool {
    value.is_none_or(|value| value.trim() != "0")
}

/// Install the Mac's mapper into the link, unless turned off.
pub fn install() {
    if !enabled() {
        tracing::info!("NAT port mapping off (CMUX_MOBILE_PORTMAP=0)");
        cmux_mobile_link::dial::portmap::install(None);
        return;
    }
    cmux_mobile_link::dial::portmap::install(Some(Arc::new(HostMapper::system())));
}

/// Where the router answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Router {
    /// The gateway (PCP and NAT-PMP go to it; an SSDP answer must come from it).
    pub gateway: Ipv4Addr,
    /// PCP and NAT-PMP port on the gateway ([`PMP_PORT`]; another in tests).
    pub pmp_port: u16,
    /// Where SSDP searches go ([`SSDP`]; a unicast fake in tests).
    pub ssdp: SocketAddr,
    /// This Mac's address toward the gateway (the mapping's internal client).
    pub local: Ipv4Addr,
}

impl Router {
    /// This Mac's router now, if it has a default IPv4 gateway.
    pub fn system() -> Option<Self> {
        let gateway = default_gateway()?;
        let local = local_toward(gateway)?;
        Some(Self { gateway, pmp_port: PMP_PORT, ssdp: SSDP, local })
    }
}

/// The protocol that maps on a router, as cached per router.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Known {
    Pcp,
    NatPmp,
    Upnp(Igd),
    /// None answered (at this instant): not asked again on this router
    /// until [`NOTHING_RETRY`] passes, so a lost burst or UPnP turned on
    /// later is found by a later session.
    Nothing(std::time::Instant),
}

/// How long a router that mapped nothing stays unasked.
pub const NOTHING_RETRY: Duration = Duration::from_secs(5 * 60);

/// An IGD's WAN connection service.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Igd {
    /// Its control URL's host and port.
    pub host: SocketAddr,
    /// Its control URL's path.
    pub path: String,
    /// Its service type (`urn:schemas-upnp-org:service:WANIPConnection:1`, ...).
    pub service: String,
}

/// The Mac's mapper: the system router, or a fixed one in tests.
pub struct HostMapper {
    router: Box<dyn Fn() -> Option<Router> + Send + Sync>,
    cache: Arc<Mutex<HashMap<(Ipv4Addr, Ipv4Addr), Known>>>,
}

impl HostMapper {
    pub fn system() -> Self {
        Self::with_router(Router::system)
    }

    pub fn with_router(router: impl Fn() -> Option<Router> + Send + Sync + 'static) -> Self {
        Self { router: Box::new(router), cache: Arc::default() }
    }

    /// Map `local_port` now (what [`PortMapper::map`] runs).
    pub async fn map_port(&self, local_port: u16) -> Option<PortMapping> {
        let router = (self.router)()?;
        let key = (router.gateway, router.local);
        let known = lock(&self.cache).get(&key).cloned();
        if let Some(Known::Nothing(at)) = known
            && at.elapsed() < NOTHING_RETRY
        {
            return None;
        }
        let found = match known {
            Some(Known::Pcp) => try_pcp(&router, local_port).await,
            Some(Known::NatPmp) => try_natpmp(&router, local_port).await,
            Some(Known::Upnp(igd)) => try_upnp_on(&router, igd, local_port).await,
            _ => None,
        };
        let found = match found {
            Some(found) => Some(found),
            // Not cached, or the cached protocol stopped answering: ask all.
            None => match try_pcp(&router, local_port).await {
                Some(found) => Some(found),
                None => match try_natpmp(&router, local_port).await {
                    Some(found) => Some(found),
                    None => try_upnp(&router, local_port).await,
                },
            },
        };
        let Some((mapped, known)) = found else {
            lock(&self.cache).insert(key, Known::Nothing(std::time::Instant::now()));
            tracing::info!(gateway = %router.gateway, "the router maps no ports (no PCP, NAT-PMP or UPnP-IGD)");
            return None;
        };
        lock(&self.cache).insert(key, known);
        if !public(mapped.external.ip()) {
            tracing::info!(
                external = %mapped.external,
                protocol = mapped.spec.protocol(),
                "the router mapped a port, but its address is not public (another NAT beyond it); not offered"
            );
            delete(router, mapped.spec).await;
            return None;
        }
        tracing::info!(local_port, external = %mapped.external, protocol = mapped.spec.protocol(), lifetime = mapped.lifetime, "port mapped");
        Some(hold(router, local_port, mapped))
    }
}

impl PortMapper for HostMapper {
    fn map(&self, local_port: u16) -> MapFuture {
        let router = (self.router)();
        let mapper = Self { router: Box::new(move || router), cache: Arc::clone(&self.cache) };
        // In its own task: a caller dropped mid-exchange (a roam, a close)
        // can't strand a grant the router already made; the task finishes,
        // and the lease it hands nobody is dropped, which deletes it.
        let task = tokio::spawn(async move { mapper.map_port(local_port).await });
        Box::pin(async move { task.await.ok().flatten() })
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A public address: not private, shared (CGNAT), loopback, link-local,
/// multicast, broadcast or unspecified.
fn public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, ..] = v4.octets();
            !(v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_multicast()
                || v4.is_broadcast()
                || v4.is_unspecified()
                || (a == 100 && (64..128).contains(&b))
                || a == 0)
        }
        IpAddr::V6(_) => false,
    }
}

/// How to renew and delete one mapping.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Spec {
    Pcp { nonce: [u8; 12], internal: u16, external: SocketAddr },
    NatPmp { internal: u16, external: u16 },
    Upnp { igd: Igd, internal: u16, external: u16 },
}

impl Spec {
    fn protocol(&self) -> &'static str {
        match self {
            Self::Pcp { .. } => "pcp",
            Self::NatPmp { .. } => "nat-pmp",
            Self::Upnp { .. } => "upnp",
        }
    }
}

/// A mapping the router granted.
#[derive(Debug, Clone)]
struct Mapped {
    external: SocketAddr,
    /// Seconds granted (0: until deleted, UPnP's permanent lease).
    lifetime: u32,
    spec: Spec,
}

/// Every live mapping, to delete at exit.
fn live() -> &'static Mutex<HashMap<u64, (Router, Spec)>> {
    static LIVE: OnceLock<Mutex<HashMap<u64, (Router, Spec)>>> = OnceLock::new();
    LIVE.get_or_init(Mutex::default)
}

/// Delete every live mapping at the router, waiting at most `limit` (the
/// host's exit).
pub async fn release_all(limit: Duration) {
    let all: Vec<(Router, Spec)> = lock(live()).drain().map(|(_, held)| held).collect();
    if all.is_empty() {
        return;
    }
    tracing::info!(count = all.len(), "deleting port mappings");
    let deletes = futures_util::future::join_all(all.into_iter().map(|(router, spec)| delete(router, spec)));
    let _ = tokio::time::timeout(limit, deletes).await;
}

/// The live mappings' protocols and external addresses (tests, debug).
pub fn live_mappings() -> Vec<(&'static str, Router)> {
    lock(live()).values().map(|(router, spec)| (spec.protocol(), *router)).collect()
}

/// Holds one mapping: renews it, and deletes it when dropped.
struct Lease {
    id: u64,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Lease {
    fn drop(&mut self) {
        self.task.abort();
        if let Some((router, spec)) = lock(live()).remove(&self.id)
            && let Ok(runtime) = tokio::runtime::Handle::try_current()
        {
            runtime.spawn(delete(router, spec));
        }
    }
}

/// Keep `mapped` alive: renew it at half its lifetime and send the external
/// address (`None` once it lapsed) to the session.
fn hold(router: Router, local_port: u16, mapped: Mapped) -> PortMapping {
    static IDS: AtomicU64 = AtomicU64::new(1);
    let id = IDS.fetch_add(1, Ordering::Relaxed);
    let protocol = mapped.spec.protocol();
    let (tx, rx) = watch::channel(Some(mapped.external));
    lock(live()).insert(id, (router, mapped.spec.clone()));
    let task = tokio::spawn(async move {
        let mut mapped = mapped;
        loop {
            if mapped.lifetime == 0 {
                // UPnP's permanent lease: nothing to renew.
                std::future::pending::<()>().await;
            }
            let lifetime = Duration::from_secs(u64::from(mapped.lifetime));
            let mut expires = tokio::time::Instant::now() + lifetime;
            tokio::time::sleep((lifetime / 2).max(Duration::from_secs(30)).min(lifetime)).await;
            let mut retries = RENEW_RETRIES.iter();
            let renewed = loop {
                if let Some(renewed) = renew(&router, local_port, &mapped.spec).await {
                    break renewed;
                }
                if tokio::time::Instant::now() >= expires {
                    tx.send_if_modified(|now| now.take().is_some());
                }
                let wait = retries.next().copied().unwrap_or(Duration::from_secs(300));
                tracing::debug!(protocol, ?wait, "port mapping renewal failed; trying again");
                tokio::time::sleep(wait).await;
                expires = expires.max(tokio::time::Instant::now());
            };
            if !public(renewed.external.ip()) {
                tx.send_if_modified(|now| now.take().is_some());
            } else {
                tx.send_if_modified(|now| now.replace(renewed.external) != Some(renewed.external));
            }
            if let Some(held) = lock(live()).get_mut(&id) {
                held.1 = renewed.spec.clone();
            }
            mapped = renewed;
        }
    });
    PortMapping { protocol, external: rx, lease: Box::new(Lease { id, task }) }
}

async fn renew(router: &Router, local_port: u16, spec: &Spec) -> Option<Mapped> {
    match spec {
        Spec::Pcp { nonce, external, .. } => {
            pcp_map(router, *nonce, local_port, Some(*external), LIFETIME_S).await
        }
        Spec::NatPmp { external, .. } => natpmp_map(router, local_port, *external, LIFETIME_S).await,
        Spec::Upnp { igd, external, .. } => upnp_add(router, igd, local_port, *external).await,
    }
}

async fn delete(router: Router, spec: Spec) {
    let done = match &spec {
        Spec::Pcp { nonce, internal, external } => {
            pcp_map(&router, *nonce, *internal, Some(*external), 0).await.is_some()
        }
        Spec::NatPmp { internal, .. } => natpmp_map(&router, *internal, 0, 0).await.is_some(),
        Spec::Upnp { igd, external, .. } => upnp_delete(igd, *external).await,
    };
    tracing::debug!(protocol = spec.protocol(), done, "port mapping deleted");
}

/// One UDP request to the gateway's PCP/NAT-PMP port, retried; the first
/// answer `accept` takes. An error answer to it (its opcode, a nonzero
/// result code: a NAT-PMP-only router's UNSUPP_VERSION to PCP, a refused
/// map) ends it at once, so the next protocol is not kept waiting.
async fn exchange<T>(router: &Router, request: &[u8], accept: impl Fn(&[u8]) -> Option<T>) -> Option<T> {
    // The local address the PCP request names as its client: never a
    // wildcard socket whose source address could differ.
    let socket = UdpSocket::bind((router.local, 0)).await.ok()?;
    let to = SocketAddr::new(IpAddr::V4(router.gateway), router.pmp_port);
    let mut buffer = [0u8; 1100];
    for wait in UDP_TRIES {
        socket.send_to(request, to).await.ok()?;
        let deadline = tokio::time::Instant::now() + wait;
        loop {
            let received = tokio::time::timeout_at(deadline, socket.recv_from(&mut buffer)).await;
            let Ok(Ok((len, from))) = received else { break };
            if from.ip() != to.ip() {
                continue;
            }
            if let Some(answer) = accept(&buffer[..len]) {
                return Some(answer);
            }
            if refused(request, &buffer[..len]) {
                return None;
            }
        }
    }
    None
}

/// An error answer to `request`: the same opcode with the answer bit, and
/// a nonzero result code (PCP: byte 3, byte 2 reserved; NAT-PMP: bytes 2-3).
fn refused(request: &[u8], answer: &[u8]) -> bool {
    request.len() >= 2 && answer.len() >= 4 && answer[1] == 0x80 | request[1] && answer[2..4] != [0, 0]
}

// ---- PCP (RFC 6887) ----

const PCP_VERSION: u8 = 2;
const PCP_MAP: u8 = 1;
const UDP: u8 = 17;

fn v4_mapped(ip: Ipv4Addr) -> [u8; 16] {
    ip.to_ipv6_mapped().octets()
}

/// A PCP MAP request (60 bytes).
pub fn pcp_request(
    client: Ipv4Addr,
    nonce: [u8; 12],
    internal: u16,
    suggested: Option<SocketAddr>,
    lifetime: u32,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(60);
    out.extend_from_slice(&[PCP_VERSION, PCP_MAP, 0, 0]);
    out.extend_from_slice(&lifetime.to_be_bytes());
    out.extend_from_slice(&v4_mapped(client));
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&[UDP, 0, 0, 0]);
    out.extend_from_slice(&internal.to_be_bytes());
    let (port, ip) = match suggested {
        Some(SocketAddr::V4(addr)) => (addr.port(), v4_mapped(*addr.ip())),
        _ => (0, v4_mapped(Ipv4Addr::UNSPECIFIED)),
    };
    out.extend_from_slice(&port.to_be_bytes());
    out.extend_from_slice(&ip);
    out
}

/// A PCP MAP success answer to `nonce` for `internal`: the external address
/// and lifetime.
pub fn pcp_answer(buf: &[u8], nonce: &[u8; 12], internal: u16) -> Option<(SocketAddr, u32)> {
    if buf.len() < 60 || buf[0] != PCP_VERSION || buf[1] != 0x80 | PCP_MAP || buf[3] != 0 {
        return None;
    }
    if &buf[24..36] != nonce || buf[36] != UDP || u16::from_be_bytes([buf[40], buf[41]]) != internal {
        return None;
    }
    let lifetime = u32::from_be_bytes(buf[4..8].try_into().ok()?);
    let port = u16::from_be_bytes([buf[42], buf[43]]);
    let ip: [u8; 16] = buf[44..60].try_into().ok()?;
    let ip = Ipv6Addr::from(ip).to_ipv4_mapped()?;
    Some((SocketAddr::new(IpAddr::V4(ip), port), lifetime))
}

async fn pcp_map(
    router: &Router,
    nonce: [u8; 12],
    internal: u16,
    suggested: Option<SocketAddr>,
    lifetime: u32,
) -> Option<Mapped> {
    let request = pcp_request(router.local, nonce, internal, suggested, lifetime);
    let (external, granted) = exchange(router, &request, |buf| pcp_answer(buf, &nonce, internal)).await?;
    Some(Mapped { external, lifetime: granted, spec: Spec::Pcp { nonce, internal, external } })
}

async fn try_pcp(router: &Router, internal: u16) -> Option<(Mapped, Known)> {
    let mut nonce = [0u8; 12];
    getrandom(&mut nonce);
    let mapped = pcp_map(router, nonce, internal, None, LIFETIME_S).await?;
    Some((mapped, Known::Pcp))
}

fn getrandom(out: &mut [u8]) {
    let id = uuid::Uuid::new_v4();
    for (byte, random) in out.iter_mut().zip(id.as_bytes().iter().cycle()) {
        *byte = *random;
    }
}

// ---- NAT-PMP (RFC 6886) ----

/// A NAT-PMP UDP mapping request (12 bytes).
pub fn natpmp_request(internal: u16, external: u16, lifetime: u32) -> [u8; 12] {
    let mut out = [0u8; 12];
    out[1] = 1;
    out[4..6].copy_from_slice(&internal.to_be_bytes());
    out[6..8].copy_from_slice(&external.to_be_bytes());
    out[8..12].copy_from_slice(&lifetime.to_be_bytes());
    out
}

/// A NAT-PMP UDP mapping success answer for `internal`: external port and lifetime.
pub fn natpmp_map_answer(buf: &[u8], internal: u16) -> Option<(u16, u32)> {
    if buf.len() < 16 || buf[0] != 0 || buf[1] != 129 || buf[2..4] != [0, 0] {
        return None;
    }
    if u16::from_be_bytes([buf[8], buf[9]]) != internal {
        return None;
    }
    Some((u16::from_be_bytes([buf[10], buf[11]]), u32::from_be_bytes(buf[12..16].try_into().ok()?)))
}

/// A NAT-PMP public address success answer.
pub fn natpmp_address_answer(buf: &[u8]) -> Option<Ipv4Addr> {
    if buf.len() < 12 || buf[0] != 0 || buf[1] != 128 || buf[2..4] != [0, 0] {
        return None;
    }
    Some(Ipv4Addr::new(buf[8], buf[9], buf[10], buf[11]))
}

async fn natpmp_map(router: &Router, internal: u16, external: u16, lifetime: u32) -> Option<Mapped> {
    let request = natpmp_request(internal, external, lifetime);
    let (port, granted) = exchange(router, &request, |buf| natpmp_map_answer(buf, internal)).await?;
    if lifetime == 0 {
        // A delete: no address to ask.
        let external = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), port);
        return Some(Mapped { external, lifetime: 0, spec: Spec::NatPmp { internal, external: port } });
    }
    let Some(ip) = exchange(router, &[0, 0], natpmp_address_answer).await else {
        // Granted, but no address to offer: give the port back now rather
        // than leave it open at the router for its whole lease.
        let delete = natpmp_request(internal, port, 0);
        let _ = exchange(router, &delete, |buf| natpmp_map_answer(buf, internal)).await;
        return None;
    };
    Some(Mapped {
        external: SocketAddr::new(IpAddr::V4(ip), port),
        lifetime: granted,
        spec: Spec::NatPmp { internal, external: port },
    })
}

async fn try_natpmp(router: &Router, internal: u16) -> Option<(Mapped, Known)> {
    let mapped = natpmp_map(router, internal, internal, LIFETIME_S).await?;
    Some((mapped, Known::NatPmp))
}

// ---- UPnP-IGD ----

/// The WAN connection services that map ports, most wanted first.
const WAN_SERVICES: [&str; 3] = [
    "urn:schemas-upnp-org:service:WANIPConnection:2",
    "urn:schemas-upnp-org:service:WANIPConnection:1",
    "urn:schemas-upnp-org:service:WANPPPConnection:1",
];

/// The SSDP search for an Internet gateway device.
pub fn ssdp_search(to: SocketAddr) -> String {
    format!(
        "M-SEARCH * HTTP/1.1\r\nHOST: {to}\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n\
         ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
    )
}

/// The `LOCATION` of an SSDP answer.
pub fn ssdp_location(answer: &str) -> Option<String> {
    answer.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.trim().eq_ignore_ascii_case("location").then(|| value.trim().to_owned())
    })
}

/// `http://host:port/path` as its address and path (IPv4 hosts only).
pub fn split_url(url: &str) -> Option<(SocketAddr, String)> {
    let rest = url.strip_prefix("http://")?;
    let (authority, path) =
        rest.split_once('/').map_or((rest, "/".to_owned()), |(a, p)| (a, format!("/{p}")));
    let addr = if authority.contains(':') {
        authority.parse().ok()?
    } else {
        format!("{authority}:80").parse().ok()?
    };
    Some((addr, path))
}

/// The text inside the first `<tag>...</tag>` of `xml` (namespace prefixes
/// on the tag allowed).
fn element<'a>(xml: &'a str, tag: &str) -> Option<&'a str> {
    let mut from = 0;
    while let Some(open) = xml[from..].find('<').map(|at| at + from) {
        let close = xml[open..].find('>').map(|at| at + open)?;
        let name = xml[open + 1..close].split_whitespace().next().unwrap_or("");
        let local = name.rsplit(':').next().unwrap_or(name);
        if local == tag && !name.starts_with('/') {
            let body = &xml[close + 1..];
            let end = body.find("</")?;
            return Some(body[..end].trim());
        }
        from = close + 1;
    }
    None
}

/// The IGD's WAN connection service in its description: its service type
/// and control URL (relative to `base`, the description's address). An
/// absolute control URL must stay on that device: the SOAP POST never goes
/// to another LAN or loopback host the description names.
pub fn igd_service(description: &str, base: SocketAddr) -> Option<Igd> {
    for wanted in WAN_SERVICES {
        for block in description.split("<service>").skip(1) {
            let block = block.split("</service>").next().unwrap_or(block);
            if element(block, "serviceType") != Some(wanted) {
                continue;
            }
            let control = element(block, "controlURL")?;
            let (host, path) = if control.starts_with("http://") {
                let (host, path) = split_url(control)?;
                if host.ip() != base.ip() {
                    return None;
                }
                (host, path)
            } else {
                let path = if control.starts_with('/') { control.to_owned() } else { format!("/{control}") };
                (base, path)
            };
            return Some(Igd { host, path, service: wanted.to_owned() });
        }
    }
    None
}

/// One HTTP/1.1 exchange (`Connection: close`): the status and body.
async fn http(to: SocketAddr, request: String) -> Option<(u16, String)> {
    tokio::time::timeout(HTTP_WAIT, async {
        let mut stream = TcpStream::connect(to).await.ok()?;
        stream.write_all(request.as_bytes()).await.ok()?;
        let mut answer = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            let n = stream.read(&mut chunk).await.ok()?;
            if n == 0 || answer.len() + n > HTTP_MAX {
                answer.extend_from_slice(&chunk[..n.min(HTTP_MAX.saturating_sub(answer.len()))]);
                break;
            }
            answer.extend_from_slice(&chunk[..n]);
        }
        let text = String::from_utf8_lossy(&answer).into_owned();
        let status = text.split_whitespace().nth(1)?.parse().ok()?;
        let body = text.split_once("\r\n\r\n").map_or(String::new(), |(_, body)| body.to_owned());
        Some((status, body))
    })
    .await
    .ok()
    .flatten()
}

/// A SOAP action on the IGD: the status and body.
async fn soap(igd: &Igd, action: &str, arguments: &str) -> Option<(u16, String)> {
    let body = format!(
        "<?xml version=\"1.0\"?>\r\n<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" \
         s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>\
         <u:{action} xmlns:u=\"{service}\">{arguments}</u:{action}></s:Body></s:Envelope>\r\n",
        service = igd.service
    );
    let request = format!(
        "POST {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: text/xml; charset=\"utf-8\"\r\n\
         SOAPAction: \"{service}#{action}\"\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}",
        path = igd.path,
        host = igd.host,
        service = igd.service,
        len = body.len()
    );
    http(igd.host, request).await
}

/// Find the gateway's IGD: an SSDP answer from the gateway (or, in tests,
/// the fake's own address), then its description.
async fn discover_igd(router: &Router) -> Option<Igd> {
    let socket = UdpSocket::bind("0.0.0.0:0").await.ok()?;
    socket.send_to(ssdp_search(router.ssdp).as_bytes(), router.ssdp).await.ok()?;
    let deadline = tokio::time::Instant::now() + SSDP_WAIT;
    let mut buffer = [0u8; 2048];
    loop {
        let (len, from) =
            tokio::time::timeout_at(deadline, socket.recv_from(&mut buffer)).await.ok()?.ok()?;
        let from_router = from.ip() == IpAddr::V4(router.gateway) || from.ip() == router.ssdp.ip();
        if !from_router {
            continue;
        }
        let Some(location) = ssdp_location(&String::from_utf8_lossy(&buffer[..len])) else { continue };
        // The description must live on the device that answered.
        let Some((host, path)) = split_url(&location) else { continue };
        if host.ip() != from.ip() {
            continue;
        }
        let request = format!("GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n");
        let Some((200, description)) = http(host, request).await else { continue };
        if let Some(igd) = igd_service(&description, host) {
            return Some(igd);
        }
    }
}

async fn upnp_external_ip(igd: &Igd) -> Option<Ipv4Addr> {
    let (status, body) = soap(igd, "GetExternalIPAddress", "").await?;
    if status != 200 {
        return None;
    }
    element(&body, "NewExternalIPAddress")?.parse().ok()
}

/// Add (or renew) the UDP mapping `external` -> `router.local:internal`:
/// a lease of [`LIFETIME_S`], else a permanent one when the router takes no
/// other (error 725).
async fn upnp_add(router: &Router, igd: &Igd, internal: u16, external: u16) -> Option<Mapped> {
    let ip = upnp_external_ip(igd).await?;
    for lease in [LIFETIME_S, 0] {
        let arguments = format!(
            "<NewRemoteHost></NewRemoteHost><NewExternalPort>{external}</NewExternalPort>\
             <NewProtocol>UDP</NewProtocol><NewInternalPort>{internal}</NewInternalPort>\
             <NewInternalClient>{client}</NewInternalClient><NewEnabled>1</NewEnabled>\
             <NewPortMappingDescription>cmux</NewPortMappingDescription>\
             <NewLeaseDuration>{lease}</NewLeaseDuration>",
            client = router.local
        );
        let (status, body) = soap(igd, "AddPortMapping", &arguments).await?;
        if status == 200 {
            return Some(Mapped {
                external: SocketAddr::new(IpAddr::V4(ip), external),
                lifetime: lease,
                spec: Spec::Upnp { igd: igd.clone(), internal, external },
            });
        }
        if element(&body, "errorCode") != Some("725") {
            tracing::debug!(status, error = element(&body, "errorCode"), "UPnP AddPortMapping refused");
            return None;
        }
    }
    None
}

async fn upnp_delete(igd: &Igd, external: u16) -> bool {
    let arguments = format!(
        "<NewRemoteHost></NewRemoteHost><NewExternalPort>{external}</NewExternalPort><NewProtocol>UDP</NewProtocol>"
    );
    matches!(soap(igd, "DeletePortMapping", &arguments).await, Some((200, _)))
}

async fn try_upnp_on(router: &Router, igd: Igd, internal: u16) -> Option<(Mapped, Known)> {
    // The same external port as the socket's, else (taken: error 718) a
    // random one above 1024.
    let mut random = [0u8; 2];
    getrandom(&mut random);
    let other = 1025 + u16::from_be_bytes(random) % (65535 - 1025);
    for external in [internal, other] {
        if let Some(mapped) = upnp_add(router, &igd, internal, external).await {
            return Some((mapped, Known::Upnp(igd)));
        }
    }
    None
}

async fn try_upnp(router: &Router, internal: u16) -> Option<(Mapped, Known)> {
    let igd = discover_igd(router).await?;
    try_upnp_on(router, igd, internal).await
}

// ---- The gateway ----

/// This Mac's address toward `gateway` (a connected UDP socket; nothing sent).
fn local_toward(gateway: Ipv4Addr) -> Option<Ipv4Addr> {
    let probe = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    probe.connect((gateway, PMP_PORT)).ok()?;
    match probe.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if !ip.is_unspecified() => Some(ip),
        _ => None,
    }
}

/// The default IPv4 gateway: the routing table's (macOS: `sysctl`
/// `NET_RT_FLAGS`; Linux: `/proc/net/route`).
pub fn default_gateway() -> Option<Ipv4Addr> {
    #[cfg(target_os = "macos")]
    {
        macos_gateway()
    }
    #[cfg(target_os = "linux")]
    {
        linux_gateway(&std::fs::read_to_string("/proc/net/route").ok()?)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        None
    }
}

/// The default route's gateway in `/proc/net/route` (hex, little-endian).
pub fn linux_gateway(table: &str) -> Option<Ipv4Addr> {
    const RTF_GATEWAY: u32 = 0x2;
    table.lines().skip(1).find_map(|line| {
        let fields: Vec<&str> = line.split_whitespace().collect();
        let (destination, gateway, flags, mask) =
            (fields.get(1)?, fields.get(2)?, fields.get(3)?, fields.get(7)?);
        let flags = u32::from_str_radix(flags, 16).ok()?;
        if *destination != "00000000" || *mask != "00000000" || flags & RTF_GATEWAY == 0 {
            return None;
        }
        let gateway = u32::from_str_radix(gateway, 16).ok()?;
        Some(Ipv4Addr::from(gateway.to_le_bytes()))
    })
}

/// The default route's gateway in a `NET_RT_FLAGS` dump: routing messages
/// (`rt_msghdr`, `header` bytes) each followed by their sockaddrs (RTA_DST,
/// RTA_GATEWAY, ... as `rtm_addrs` says), each padded to 4 bytes.
pub fn rt_dump_gateway(dump: &[u8], header: usize) -> Option<Ipv4Addr> {
    const RTA_DST: i32 = 0x1;
    const RTA_GATEWAY: i32 = 0x2;
    const AF_INET: u8 = 2;
    let mut at = 0;
    while at + header <= dump.len() {
        let len = usize::from(u16::from_ne_bytes([dump[at], dump[at + 1]]));
        if len < header || at + len > dump.len() {
            return None;
        }
        let message = &dump[at..at + len];
        at += len;
        let addrs = i32::from_ne_bytes(message[12..16].try_into().ok()?);
        if addrs & (RTA_DST | RTA_GATEWAY) != (RTA_DST | RTA_GATEWAY) {
            continue;
        }
        let mut sockaddrs = &message[header..];
        let mut next = || -> Option<&[u8]> {
            let sa_len = usize::from(*sockaddrs.first()?);
            let step = if sa_len == 0 { 4 } else { sa_len.div_ceil(4) * 4 };
            let (sockaddr, rest) = sockaddrs.split_at(step.min(sockaddrs.len()));
            sockaddrs = rest;
            Some(&sockaddr[..sa_len.min(sockaddr.len())])
        };
        let (Some(destination), Some(gateway)) = (next(), next()) else { continue };
        let ipv4 = |sockaddr: &[u8]| {
            (sockaddr.len() >= 8 && sockaddr[1] == AF_INET)
                .then(|| Ipv4Addr::new(sockaddr[4], sockaddr[5], sockaddr[6], sockaddr[7]))
        };
        if ipv4(destination) == Some(Ipv4Addr::UNSPECIFIED)
            && let Some(gateway) = ipv4(gateway)
            && !gateway.is_unspecified()
        {
            return Some(gateway);
        }
    }
    None
}

#[cfg(target_os = "macos")]
fn macos_gateway() -> Option<Ipv4Addr> {
    let mut mib = [libc::CTL_NET, libc::PF_ROUTE, 0, libc::AF_INET, libc::NET_RT_FLAGS, libc::RTF_GATEWAY];
    let mut size: libc::size_t = 0;
    // SAFETY: sysctl with a null buffer only reports the size.
    let found = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if found != 0 || size == 0 {
        return None;
    }
    let mut dump = vec![0u8; size + 512];
    let mut size = dump.len();
    // SAFETY: the buffer is `size` bytes; sysctl writes at most that.
    let found = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            dump.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if found != 0 {
        return None;
    }
    rt_dump_gateway(&dump[..size], std::mem::size_of::<libc::rt_msghdr>())
}

#[cfg(test)]
#[path = "portmap_tests.rs"]
mod tests;
