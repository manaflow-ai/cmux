//! LAN direct path (PROTOCOL.md "LAN direct path"): when the phone and its
//! paired Mac share a network, the phone reaches the Mac's WireGuard mesh
//! directly, with no signaling Worker, token, ICE or STUN round trip, and it
//! works with the internet down.
//!
//! - Keys: each side holds one long-lived Curve25519 key for this path
//!   ([`LanIdentity`]). The phone enrolls its public key over an already
//!   authenticated link (the `lan` service, served only after `auth` proved
//!   the phone's Secure Enclave key), and learns the Mac's key, port, LAN
//!   addresses and the overlay address the Mac gave it ([`LanEnrollReply`]).
//!   Nothing on the LAN is trusted: the WireGuard handshake (Noise IK, the
//!   same tunnel crypto as the relayed path) proves both static keys, the
//!   mesh answers no unknown key, and the link's `auth` channel runs on top as
//!   on every other path.
//! - Mac: one [`LanHost`] (a [`cmux_wg::WgMesh`] on UDP [`LAN_PORT`]) with
//!   every enrolled phone as a peer. Its link stream is TCP to
//!   `MAC_OVERLAY:7420` inside the mesh, the input lane TCP to
//!   [`LAN_LANE_PORT`], each matched to its phone by the session's key.
//! - Phone: [`dial`] starts a one-peer [`cmux_wg::WgNet`] toward each
//!   remembered address of the Mac (most recent success first) and keeps the
//!   first whose tunnel carries the link's TCP connection.
//! - Memory ([`LanMemory`]): the phone's key and, per Mac, what enrollment
//!   returned plus the address that last worked, per network, so the next
//!   connect tries it before any discovery answers.

use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use base64::Engine;
use cmux_wg::{InterfaceAddress, IpNetwork, UltraChoice, WgConfig, WgMesh, WgMeshConfig, WgNet, WgPeer};
use serde::{Deserialize, Serialize};
use tokio::sync::{oneshot, watch};
use zeroize::Zeroizing;

use crate::dial::{DialError, Dialed, LinkPath, LinkStream};

/// The Mac's UDP port for the LAN mesh. Another process holding it moves the
/// mesh to any free port, which enrollment reports.
pub const LAN_PORT: u16 = 7421;
/// The link's main stream inside the mesh (the same port as the relayed
/// WireGuard path's).
pub const LAN_LINK_PORT: u16 = crate::dial::wireguard::LINK_PORT;
/// The input lane's stream inside the mesh: its own port, so the Mac never
/// tells the two apart by arrival order.
pub const LAN_LANE_PORT: u16 = 7422;
/// The service a phone opens on an authenticated link to enroll for the LAN
/// path.
pub const LAN_SERVICE: &str = "lan";
/// The Mac's address inside the LAN mesh.
pub const MAC_OVERLAY: Ipv4Addr = Ipv4Addr::new(10, 78, 0, 1);
/// The tunnel MTU: a LAN needs no room for TURN headers, but the phone's
/// path may still cross a VPN or Wi-Fi bridge; the relayed path's value.
const MTU: u16 = 1280;
/// How long one address may take, handshake and TCP, before it counts as
/// not this Mac. A LAN answers in milliseconds; this bounds a remembered
/// address on a network the Mac is not on.
pub const ADDRESS_TIMEOUT: Duration = Duration::from_millis(1500);
/// Later addresses start this long after the one before (RFC 8305's stagger),
/// so the remembered one usually wins alone.
const STAGGER: Duration = Duration::from_millis(150);
/// How long the input lane may take after the main stream.
const LANE_TIMEOUT: Duration = Duration::from_secs(5);
const KEEPALIVE_SECONDS: u16 = 10;

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// A base64 Curve25519 key.
pub fn parse_key(text: &str) -> Option<[u8; 32]> {
    base64::engine::general_purpose::STANDARD.decode(text.trim()).ok()?.try_into().ok()
}

/// One side's long-lived key for the LAN path.
#[derive(Clone)]
pub struct LanIdentity {
    private: Zeroizing<[u8; 32]>,
    public: [u8; 32],
}

impl std::fmt::Debug for LanIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LanIdentity").field("public", &b64(&self.public)).finish_non_exhaustive()
    }
}

impl LanIdentity {
    pub fn generate() -> Self {
        let mut private = Zeroizing::new([0u8; 32]);
        getrandom::fill(&mut private[..]).expect("operating system randomness");
        Self::from_private(*private)
    }

    pub fn from_private(private: [u8; 32]) -> Self {
        let secret = x25519_dalek::StaticSecret::from(private);
        let public = x25519_dalek::PublicKey::from(&secret).to_bytes();
        Self { private: Zeroizing::new(secret.to_bytes()), public }
    }

    pub fn public(&self) -> [u8; 32] {
        self.public
    }

    pub fn public_b64(&self) -> String {
        b64(&self.public)
    }

    fn private_b64(&self) -> String {
        b64(&self.private[..])
    }

    /// The key in a file of its own (`0600`), made on first use.
    pub fn load_or_create(path: &Path) -> io::Result<Self> {
        if let Ok(text) = std::fs::read_to_string(path)
            && let Some(private) = parse_key(&text)
        {
            return Ok(Self::from_private(private));
        }
        let identity = Self::generate();
        write_private(path, identity.private_b64().as_bytes())?;
        Ok(identity)
    }
}

/// Write `bytes` to `path` readable by its owner only, replacing it whole.
fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let partial = path.with_extension("partial");
    {
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&partial)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    std::fs::rename(&partial, path)
}

/// Phone → Mac, the `lan` service's args.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LanEnrollRequest {
    /// The phone's LAN public key (base64).
    pub phone_key: String,
}

/// Mac → phone, the `lan` service's one reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LanEnrollReply {
    /// The Mac's LAN public key (base64).
    pub mac_key: String,
    /// The Mac's LAN mesh UDP port.
    pub port: u16,
    /// The Mac's addresses on its networks right now (IP literals).
    pub addresses: Vec<String>,
    /// The phone's address inside the mesh.
    pub phone_overlay: String,
    /// RFD 0164 T5: this Mac's own tailnet addresses, sent only while its
    /// `transport.tailnetCarrier` is not `off` and it sees itself on a
    /// tailnet. Absent from an old Mac's reply (a new phone reads `None`), and
    /// an old phone ignores the unknown field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tailnet: Option<TailnetHint>,
}

/// The hint's shape version; a phone reads only a version it knows.
pub const TAILNET_HINT_VERSION: u32 = 1;

/// The Mac's tailnet addresses, reported to the phone (RFD 0164 T5).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TailnetHint {
    /// [`TAILNET_HINT_VERSION`] when written.
    pub v: u32,
    /// IP literals in the tailnet ranges (100.64.0.0/10), reached on the
    /// same mesh port as the LAN addresses.
    pub addresses: Vec<String>,
}

/// The Mac's addresses on a tailnet: its interfaces' IPv4 addresses in
/// 100.64.0.0/10 (the mesh is bound to every interface, the tailnet's too).
pub fn tailnet_addresses() -> Vec<IpAddr> {
    let mut found = Vec::new();
    for ip in crate::dial::wireguard::interface_ips() {
        if ip.is_ipv4() && crate::dial::is_cgnat(ip) && !found.contains(&ip) {
            found.push(ip);
        }
    }
    found
}

/// The hint a Mac adds to its enroll reply: `None` when its carrier setting
/// is off (`carrier_on` false) or it has no tailnet address.
pub fn tailnet_hint(carrier_on: bool, addresses: &[IpAddr]) -> Option<TailnetHint> {
    if !carrier_on {
        return None;
    }
    let addresses: Vec<String> =
        addresses.iter().filter(|ip| tailnet_ip(**ip)).map(ToString::to_string).collect();
    (!addresses.is_empty()).then_some(TailnetHint { v: TAILNET_HINT_VERSION, addresses })
}

fn tailnet_ip(ip: IpAddr) -> bool {
    ip.is_ipv4() && crate::dial::is_cgnat(ip)
}

/// The Mac's addresses a phone on the same network may reach: every
/// private IPv4 address of its interfaces that are up (loopback with
/// `include_loopback`). Tailscale-style CGNAT addresses are left out: that
/// path is not the LAN and has its own routes.
pub fn local_addresses(include_loopback: bool) -> Vec<IpAddr> {
    let mut found = Vec::new();
    if let Some(ip) = crate::dial::wireguard::primary_local_ip()
        && lan_address(ip, include_loopback)
    {
        found.push(ip);
    }
    for ip in crate::dial::wireguard::interface_ips() {
        if lan_address(ip, include_loopback) && !found.contains(&ip) {
            found.push(ip);
        }
    }
    if include_loopback && !found.iter().any(IpAddr::is_loopback) {
        found.push(IpAddr::V4(Ipv4Addr::LOCALHOST));
    }
    found
}

fn lan_address(ip: IpAddr, include_loopback: bool) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            (v4.is_private() || v4.is_link_local() || (include_loopback && v4.is_loopback()))
                && !crate::dial::is_cgnat(ip)
        }
        IpAddr::V6(_) => false,
    }
}

/// A phone the Mac accepts on the LAN path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnrolledPhone {
    pub device_id: String,
    pub key: String,
    pub overlay: Ipv4Addr,
}

/// The Mac's enrolled phones, kept in one JSON file.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
struct EnrolledFile {
    #[serde(default)]
    phones: Vec<EnrolledPhone>,
}

/// A link stream the Mac accepted on the LAN mesh.
pub struct LanAccepted {
    /// The phone's device id, from its enrollment (never from the LAN).
    pub device_id: String,
    pub dialed: Dialed,
}

struct HostState {
    phones: Vec<EnrolledPhone>,
    /// Main streams waiting for their input lane, by phone key.
    lanes: HashMap<[u8; 32], oneshot::Sender<Box<dyn LinkStream>>>,
    /// Input lanes that arrived before their main stream, by phone key.
    early: HashMap<[u8; 32], Box<dyn LinkStream>>,
}

/// The Mac side: the LAN mesh, its enrolled phones, and the links they
/// open.
pub struct LanHost {
    mesh: Arc<WgMesh>,
    identity: LanIdentity,
    port: u16,
    include_loopback: bool,
    state: Arc<Mutex<HostState>>,
    store: Option<PathBuf>,
    accepted: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<LanAccepted>>,
}

impl std::fmt::Debug for LanHost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LanHost").field("port", &self.port).finish_non_exhaustive()
    }
}

/// Bind the mesh's UDP socket: [`LAN_PORT`], else any port.
fn bind_mesh_socket(port: u16) -> io::Result<tokio::net::UdpSocket> {
    let bind = |port: u16| -> io::Result<tokio::net::UdpSocket> {
        let socket =
            socket2::Socket::new(socket2::Domain::IPV4, socket2::Type::DGRAM, Some(socket2::Protocol::UDP))?;
        let _ = socket.set_recv_buffer_size(2 * 1024 * 1024);
        let _ = socket.set_send_buffer_size(2 * 1024 * 1024);
        socket.set_nonblocking(true)?;
        socket.bind(&SocketAddr::from((Ipv4Addr::UNSPECIFIED, port)).into())?;
        tokio::net::UdpSocket::from_std(socket.into())
    };
    bind(port).or_else(|error| {
        tracing::info!(port, %error, "LAN port taken; the LAN mesh takes any free port");
        bind(0)
    })
}

fn mesh_peer(phone: &EnrolledPhone) -> Option<WgPeer> {
    let public_key = parse_key(&phone.key)?;
    Some(WgPeer {
        public_key,
        preshared_key: None,
        allowed_ips: vec![IpNetwork::new(IpAddr::V4(phone.overlay), 32).ok()?],
        route: None,
        candidates: Vec::new(),
        persistent_keepalive: None,
    })
}

impl LanHost {
    /// Start the mesh with `identity` on `port` ([`LAN_PORT`] in the app; 0
    /// in tests), with the phones `store` (a JSON file) enrolled before.
    pub async fn start(
        identity: LanIdentity,
        port: u16,
        store: Option<PathBuf>,
        include_loopback: bool,
    ) -> io::Result<Self> {
        let socket = bind_mesh_socket(port)?;
        let port = socket.local_addr()?.port();
        let config = WgMeshConfig {
            private_key: identity.private.clone(),
            addresses: vec![InterfaceAddress { address: IpAddr::V4(MAC_OVERLAY), prefix: 16 }],
            mtu: MTU,
        };
        let mesh = Arc::new(WgMesh::start(config, socket).map_err(io::Error::other)?);
        let phones = store
            .as_deref()
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice::<EnrolledFile>(&bytes).ok())
            .unwrap_or_default()
            .phones;
        for phone in &phones {
            if let Some(peer) = mesh_peer(phone) {
                let _ = mesh.add_peer(peer).await;
            }
        }
        let state = Arc::new(Mutex::new(HostState { phones, lanes: HashMap::new(), early: HashMap::new() }));
        let (tx, rx) = tokio::sync::mpsc::channel(16);
        let mut main = mesh.listen(LAN_LINK_PORT).await.map_err(io::Error::other)?;
        let mut lanes = mesh.listen(LAN_LANE_PORT).await.map_err(io::Error::other)?;
        let lane_state = Arc::clone(&state);
        tokio::spawn(async move {
            while let Some((stream, key)) = lanes.accept().await {
                let stream = Box::new(stream) as Box<dyn LinkStream>;
                let waiting = {
                    let mut state = lane_state.lock().unwrap_or_else(PoisonError::into_inner);
                    match state.lanes.remove(&key) {
                        Some(tx) => Some((tx, stream)),
                        None => {
                            // Its main stream is still being accepted.
                            state.early.insert(key, stream);
                            None
                        }
                    }
                };
                match waiting {
                    Some((tx, stream)) => {
                        let _ = tx.send(stream);
                    }
                    None => {
                        let early_state = Arc::clone(&lane_state);
                        tokio::spawn(async move {
                            tokio::time::sleep(LANE_TIMEOUT).await;
                            early_state.lock().unwrap_or_else(PoisonError::into_inner).early.remove(&key);
                        });
                    }
                }
            }
        });
        let main_state = Arc::clone(&state);
        let main_mesh = Arc::downgrade(&mesh);
        tokio::spawn(async move {
            while let Some((stream, key)) = main.accept().await {
                let Some(device_id) = ({
                    let state = main_state.lock().unwrap_or_else(PoisonError::into_inner);
                    state
                        .phones
                        .iter()
                        .find(|phone| parse_key(&phone.key) == Some(key))
                        .map(|phone| phone.device_id.clone())
                }) else {
                    // A peer removed between its handshake and its SYN.
                    continue;
                };
                let (lane_tx, lane_rx) = oneshot::channel();
                {
                    let mut state = main_state.lock().unwrap_or_else(PoisonError::into_inner);
                    match state.early.remove(&key) {
                        Some(early) => {
                            let _ = lane_tx.send(early);
                        }
                        None => {
                            state.lanes.insert(key, lane_tx);
                        }
                    }
                }
                let lane_state = Arc::clone(&main_state);
                tokio::spawn(async move {
                    tokio::time::sleep(LANE_TIMEOUT).await;
                    lane_state.lock().unwrap_or_else(PoisonError::into_inner).lanes.remove(&key);
                });
                let (_path_tx, path) = watch::channel(LinkPath::Direct);
                let guard: Box<dyn std::any::Any + Send> = Box::new((main_mesh.clone(), _path_tx));
                let dialed = Dialed {
                    stream: Box::new(stream),
                    path,
                    // The mesh does not say which LAN address the phone's packets came from.
                    peer: watch::channel(None).1,
                    guard,
                    lane: Some(lane_rx),
                    media: None,
                    webrtc_media: false,
                    hold: None,
                    liveness: None,
                    on_link: None,
                    reliable: false,
                    tunnel_keys: None,
                    overlay: None,
                };
                if tx.send(LanAccepted { device_id, dialed }).await.is_err() {
                    return;
                }
            }
        });
        Ok(Self {
            mesh,
            identity,
            port,
            include_loopback,
            state,
            store,
            accepted: tokio::sync::Mutex::new(rx),
        })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn public_b64(&self) -> String {
        self.identity.public_b64()
    }

    /// The next link a phone opened on the LAN, or `None` once the mesh is
    /// gone.
    pub async fn accept(&self) -> Option<LanAccepted> {
        self.accepted.lock().await.recv().await
    }

    /// Enroll `device_id` (proven by the link's `auth`) with `request`, or
    /// replace its key; returns what the phone keeps.
    pub async fn enroll(
        &self,
        device_id: &str,
        request: &LanEnrollRequest,
    ) -> Result<LanEnrollReply, String> {
        self.enroll_hinting(device_id, request, false).await
    }

    /// [`Self::enroll`], adding this Mac's [`TailnetHint`] when `tailnet_carrier`
    /// (its `transport.tailnetCarrier` is not `off`) and it is on a tailnet.
    pub async fn enroll_hinting(
        &self,
        device_id: &str,
        request: &LanEnrollRequest,
        tailnet_carrier: bool,
    ) -> Result<LanEnrollReply, String> {
        let key = parse_key(&request.phone_key).ok_or("phoneKey is not a base64 Curve25519 key")?;
        let (phone, replaced, snapshot) = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let replaced: Vec<EnrolledPhone> = state
                .phones
                .iter()
                .filter(|phone| phone.device_id == device_id || parse_key(&phone.key) == Some(key))
                .cloned()
                .collect();
            state.phones.retain(|phone| phone.device_id != device_id && parse_key(&phone.key) != Some(key));
            let overlay = replaced
                .iter()
                .find(|phone| phone.device_id == device_id)
                .map(|phone| phone.overlay)
                .or_else(|| free_overlay(&state.phones))
                .ok_or("no overlay address left")?;
            let phone =
                EnrolledPhone { device_id: device_id.to_owned(), key: request.phone_key.clone(), overlay };
            state.phones.push(phone.clone());
            (phone, replaced, EnrolledFile { phones: state.phones.clone() })
        };
        for old in &replaced {
            if let Some(old_key) = parse_key(&old.key)
                && old_key != key
            {
                let _ = self.mesh.remove_peer(old_key).await;
            }
        }
        let peer = mesh_peer(&phone).ok_or("bad enrolled phone")?;
        self.mesh.add_peer(peer).await.map_err(|error| error.to_string())?;
        self.save(&snapshot);
        Ok(LanEnrollReply {
            mac_key: self.identity.public_b64(),
            port: self.port,
            addresses: local_addresses(self.include_loopback).iter().map(ToString::to_string).collect(),
            phone_overlay: phone.overlay.to_string(),
            tailnet: tailnet_hint(tailnet_carrier, &tailnet_addresses()),
        })
    }

    /// The owner removed this phone: its LAN key no longer opens anything.
    pub async fn remove(&self, device_id: &str) {
        let (removed, snapshot) = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let removed: Vec<EnrolledPhone> = state
                .phones
                .iter()
                .filter(|phone| phone.device_id.eq_ignore_ascii_case(device_id))
                .cloned()
                .collect();
            state.phones.retain(|phone| !phone.device_id.eq_ignore_ascii_case(device_id));
            (removed, EnrolledFile { phones: state.phones.clone() })
        };
        for phone in &removed {
            if let Some(key) = parse_key(&phone.key) {
                let _ = self.mesh.remove_peer(key).await;
            }
        }
        if !removed.is_empty() {
            self.save(&snapshot);
        }
    }

    fn save(&self, file: &EnrolledFile) {
        let Some(path) = &self.store else { return };
        match serde_json::to_vec_pretty(file) {
            Ok(bytes) => {
                if let Err(error) = write_private(path, &bytes) {
                    tracing::warn!(%error, "LAN enrollments not saved");
                }
            }
            Err(error) => tracing::warn!(%error, "LAN enrollments not encoded"),
        }
    }
}

/// The lowest phone overlay address in 10.78.0.0/16 no phone holds.
fn free_overlay(phones: &[EnrolledPhone]) -> Option<Ipv4Addr> {
    (2u32..0xfffe)
        .map(|index| Ipv4Addr::new(10, 78, (index >> 8) as u8, (index & 0xff) as u8))
        .find(|candidate| !phones.iter().any(|phone| phone.overlay == *candidate))
}

/// What a phone keeps for one Mac.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LanMac {
    pub mac_key: String,
    pub port: u16,
    pub phone_overlay: Ipv4Addr,
    /// What enrollment reported, newest first.
    pub addresses: Vec<String>,
    /// The address that last carried a link, per network the phone was on
    /// (its own LAN address's /24, [`network_tag`]).
    #[serde(default)]
    pub last_ok: HashMap<String, String>,
    /// The Mac's tailnet addresses from its [`TailnetHint`] (RFD 0164 T5);
    /// empty from an old Mac or one whose carrier setting is off.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tailnet: Vec<String>,
}

impl LanMac {
    pub fn from_reply(reply: &LanEnrollReply) -> Option<Self> {
        parse_key(&reply.mac_key)?;
        Some(Self {
            mac_key: reply.mac_key.clone(),
            port: reply.port,
            phone_overlay: reply.phone_overlay.parse().ok()?,
            addresses: reply.addresses.clone(),
            last_ok: HashMap::new(),
            tailnet: reply
                .tailnet
                .as_ref()
                .filter(|hint| hint.v == TAILNET_HINT_VERSION)
                .map(|hint| {
                    hint.addresses
                        .iter()
                        .filter(|text| text.parse::<IpAddr>().is_ok_and(tailnet_ip))
                        .cloned()
                        .collect()
                })
                .unwrap_or_default(),
        })
    }

    /// The addresses to try, in order: the one that last worked on
    /// `network`, then the ones enrollment reported (or a discovery answer
    /// added). No tailnet address: [`Self::candidates_with`] adds those.
    pub fn candidates(&self, network: Option<&str>) -> Vec<SocketAddr> {
        self.candidates_with(network, false)
    }

    /// [`Self::candidates`], then, with `tailnet` (the phone's carrier
    /// setting is not `off`), the Mac's tailnet addresses on the mesh port:
    /// a `Direct` tailnet candidate raced beside the LAN ones and the relay.
    /// A tailnet address that last worked goes first only with `tailnet`.
    pub fn candidates_with(&self, network: Option<&str>, tailnet: bool) -> Vec<SocketAddr> {
        let mut out: Vec<SocketAddr> = Vec::new();
        let first = network.and_then(|network| self.last_ok.get(network));
        let reported = if tailnet { self.tailnet.as_slice() } else { &[] };
        for text in first.into_iter().chain(self.addresses.iter()).chain(reported) {
            let Some(address) = parse_address(text, self.port) else { continue };
            if tailnet_ip(address.ip()) && !tailnet {
                continue;
            }
            if !out.contains(&address) {
                out.push(address);
            }
        }
        out
    }
}

fn parse_address(text: &str, port: u16) -> Option<SocketAddr> {
    text.parse::<SocketAddr>()
        .ok()
        .or_else(|| text.parse::<IpAddr>().ok().map(|ip| SocketAddr::new(ip, port)))
        .filter(SocketAddr::is_ipv4)
}

/// The network the phone is on, as the LAN path remembers it: the /24 of its
/// primary local IPv4 address (no packet is sent). `None` off any network.
pub fn network_tag() -> Option<String> {
    match crate::dial::wireguard::primary_local_ip()? {
        IpAddr::V4(v4) if !v4.is_loopback() => {
            let [a, b, c, _] = v4.octets();
            Some(format!("{a}.{b}.{c}.0/24"))
        }
        _ => None,
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MemoryFile {
    #[serde(default)]
    phone_key: Option<String>,
    #[serde(default)]
    macs: HashMap<String, LanMac>,
}

/// The phone's LAN memory: its key and every enrolled Mac, in one file
/// (`0600`, in the app's own container).
#[derive(Debug, Clone)]
pub struct LanMemory {
    path: PathBuf,
    inner: Arc<Mutex<MemoryFile>>,
}

impl LanMemory {
    pub fn open(path: PathBuf) -> Self {
        let file = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<MemoryFile>(&bytes).ok())
            .unwrap_or_default();
        Self { path, inner: Arc::new(Mutex::new(file)) }
    }

    /// The phone's key, made and saved on first use.
    pub fn identity(&self) -> LanIdentity {
        let mut file = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(private) = file.phone_key.as_deref().and_then(parse_key) {
            return LanIdentity::from_private(private);
        }
        let identity = LanIdentity::generate();
        file.phone_key = Some(identity.private_b64());
        self.save(&file);
        identity
    }

    pub fn mac(&self, mac_device_id: &str) -> Option<LanMac> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner).macs.get(mac_device_id).cloned()
    }

    /// Keep what enrollment with `mac_device_id` returned; the addresses that
    /// last worked stay when the Mac's key did not change.
    pub fn enrolled(&self, mac_device_id: &str, mut mac: LanMac) {
        let mut file = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(old) = file.macs.get(mac_device_id)
            && old.mac_key == mac.mac_key
        {
            mac.last_ok = old.last_ok.clone();
        }
        file.macs.insert(mac_device_id.to_owned(), mac);
        self.save(&file);
    }

    /// `address` carried a link to `mac_device_id` on `network`.
    pub fn worked(&self, mac_device_id: &str, network: Option<&str>, address: SocketAddr) {
        let Some(network) = network else { return };
        let mut file = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(mac) = file.macs.get_mut(mac_device_id) else { return };
        if mac.last_ok.get(network) == Some(&address.to_string()) {
            return;
        }
        mac.last_ok.insert(network.to_owned(), address.to_string());
        self.save(&file);
    }

    /// Forget `mac_device_id` (its key changed or it was removed).
    pub fn forget(&self, mac_device_id: &str) {
        let mut file = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if file.macs.remove(mac_device_id).is_some() {
            self.save(&file);
        }
    }

    fn save(&self, file: &MemoryFile) {
        match serde_json::to_vec(file) {
            Ok(bytes) => {
                if let Err(error) = write_private(&self.path, &bytes) {
                    tracing::warn!(%error, "LAN memory not saved");
                }
            }
            Err(error) => tracing::warn!(%error, "LAN memory not encoded"),
        }
    }
}

/// A LAN dial that worked: the transport and the address that carried it.
pub struct LanDialed {
    pub dialed: Dialed,
    pub address: SocketAddr,
}

/// Phone side: reach `mac` at `candidates` (in order, staggered) and return
/// the first tunnel whose link stream connects, or an error once every
/// address failed or timed out.
pub async fn dial(
    identity: &LanIdentity,
    mac: &LanMac,
    candidates: Vec<SocketAddr>,
    timeline: &crate::Timeline,
) -> Result<LanDialed, DialError> {
    let peer_key = parse_key(&mac.mac_key).ok_or_else(|| DialError::Unexpected("bad LAN Mac key".into()))?;
    if candidates.is_empty() {
        return Err(DialError::Transport("no LAN address for this Mac".into()));
    }
    timeline.mark("lan_dial_start");
    let mut attempts = futures_util::stream::FuturesUnordered::new();
    for (index, address) in candidates.into_iter().enumerate() {
        let identity = identity.clone();
        let phone_overlay = mac.phone_overlay;
        attempts.push(async move {
            tokio::time::sleep(STAGGER * index as u32).await;
            let result =
                tokio::time::timeout(ADDRESS_TIMEOUT, dial_one(&identity, peer_key, phone_overlay, address))
                    .await;
            match result {
                Ok(Ok(dialed)) => Ok(LanDialed { dialed, address }),
                Ok(Err(error)) => Err(error),
                Err(_) => Err(DialError::Timeout),
            }
        });
    }
    let mut last = DialError::Timeout;
    use futures_util::StreamExt;
    while let Some(result) = attempts.next().await {
        match result {
            Ok(dialed) => {
                timeline.mark("lan_link_stream");
                return Ok(dialed);
            }
            Err(error) => last = error,
        }
    }
    Err(last)
}

async fn dial_one(
    identity: &LanIdentity,
    peer_key: [u8; 32],
    phone_overlay: Ipv4Addr,
    address: SocketAddr,
) -> Result<Dialed, DialError> {
    let transport = |error: cmux_wg::WgError| DialError::Transport(error.to_string());
    let socket =
        crate::dial::wireguard::bind_udp().map_err(|error| DialError::Transport(error.to_string()))?;
    let config = WgConfig {
        private_key: identity.private.clone(),
        addresses: vec![InterfaceAddress { address: IpAddr::V4(phone_overlay), prefix: 32 }],
        mtu: MTU,
        peer_public_key: peer_key,
        preshared_key: None,
        allowed_ips: vec![IpNetwork::new(IpAddr::V4(MAC_OVERLAY), 32).expect("host prefix")],
        endpoint: Some(cmux_wg::Endpoint { host: address.ip().to_string(), port: address.port() }),
        persistent_keepalive: Some(KEEPALIVE_SECONDS),
        peer_addresses: vec![IpAddr::V4(MAC_OVERLAY)],
        ultra: UltraChoice::Off,
    };
    let net = Arc::new(WgNet::start(config, socket).await.map_err(transport)?);
    let stream =
        net.connect(SocketAddr::new(IpAddr::V4(MAC_OVERLAY), LAN_LINK_PORT)).await.map_err(transport)?;
    let (lane_tx, lane_rx) = oneshot::channel();
    let lane_net = Arc::clone(&net);
    tokio::spawn(async move {
        let lane = SocketAddr::new(IpAddr::V4(MAC_OVERLAY), LAN_LANE_PORT);
        match tokio::time::timeout(LANE_TIMEOUT, lane_net.connect(lane)).await {
            Ok(Ok(stream)) => {
                let _ = lane_tx.send(Box::new(stream) as Box<dyn LinkStream>);
            }
            Ok(Err(error)) => tracing::info!(%error, "LAN input lane did not connect"),
            Err(_) => tracing::info!("LAN input lane did not connect in time"),
        }
    });
    let (path_tx, path) = watch::channel(LinkPath::Direct);
    Ok(Dialed {
        stream: Box::new(stream),
        path,
        // The Mac's LAN address this tunnel goes to (a direct-lan route).
        peer: watch::channel(Some(address.ip())).1,
        guard: Box::new((net, path_tx)),
        lane: Some(lane_rx),
        media: None,
        webrtc_media: false,
        hold: None,
        liveness: None,
        on_link: None,
        reliable: false,
        tunnel_keys: None,
        overlay: None,
    })
}

/// Phone side: [`dial`] and run a link on it.
pub async fn connect(
    identity: &LanIdentity,
    mac: &LanMac,
    candidates: Vec<SocketAddr>,
    link_config: crate::link::LinkConfig,
    timeline: &crate::Timeline,
) -> Result<(crate::dial::Connected, SocketAddr), DialError> {
    let LanDialed { dialed, address } = dial(identity, mac, candidates, timeline).await?;
    let connected = crate::dial::run_dialed(
        dialed,
        crate::link::Role::Phone,
        link_config,
        crate::TransportKind::WireGuard,
    );
    timeline.mark("link_ready");
    Ok((connected, address))
}

/// Mac side: run a link on what [`LanHost::accept`] returned.
pub fn answer(
    accepted: LanAccepted,
    link_config: crate::link::LinkConfig,
) -> (String, crate::dial::Connected) {
    let connected = crate::dial::run_dialed(
        accepted.dialed,
        crate::link::Role::Mac,
        link_config,
        crate::TransportKind::WireGuard,
    );
    (accepted.device_id, connected)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_round_trips_through_its_file() {
        let dir = std::env::temp_dir().join(format!("cmux-lan-{}", uuid::Uuid::new_v4()));
        let path = dir.join("lan.key");
        let first = LanIdentity::load_or_create(&path).unwrap();
        let again = LanIdentity::load_or_create(&path).unwrap();
        assert_eq!(first.public(), again.public());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_address_that_last_worked_on_this_network_goes_first() {
        let mut mac = LanMac {
            mac_key: LanIdentity::generate().public_b64(),
            port: 7421,
            phone_overlay: Ipv4Addr::new(10, 78, 0, 2),
            addresses: vec!["192.168.1.20".into(), "10.0.0.5".into()],
            last_ok: HashMap::new(),
            tailnet: Vec::new(),
        };
        assert_eq!(
            mac.candidates(Some("10.0.0.0/24")),
            vec![
                "192.168.1.20:7421".parse::<SocketAddr>().unwrap(),
                "10.0.0.5:7421".parse::<SocketAddr>().unwrap()
            ]
        );
        mac.last_ok.insert("10.0.0.0/24".into(), "10.0.0.5:7421".into());
        assert_eq!(
            mac.candidates(Some("10.0.0.0/24")),
            vec![
                "10.0.0.5:7421".parse::<SocketAddr>().unwrap(),
                "192.168.1.20:7421".parse::<SocketAddr>().unwrap()
            ]
        );
        // Another network keeps enrollment's order.
        assert_eq!(
            mac.candidates(Some("172.16.0.0/24"))[0],
            "192.168.1.20:7421".parse::<SocketAddr>().unwrap()
        );
    }

    fn reply(tailnet: Option<TailnetHint>) -> LanEnrollReply {
        LanEnrollReply {
            mac_key: LanIdentity::generate().public_b64(),
            port: 7421,
            addresses: vec!["192.168.1.20".into()],
            phone_overlay: "10.78.0.2".into(),
            tailnet,
        }
    }

    /// The enroll reply as a phone built before T5 parses it.
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    #[allow(dead_code)]
    struct OldReply {
        mac_key: String,
        port: u16,
        addresses: Vec<String>,
        phone_overlay: String,
    }

    #[test]
    fn a_new_phone_reads_no_tailnet_from_an_old_mac() {
        let old_mac =
            r#"{"macKey":"KEY","port":7421,"addresses":["192.168.1.20"],"phoneOverlay":"10.78.0.2"}"#;
        let mut parsed: LanEnrollReply = serde_json::from_str(old_mac).unwrap();
        assert_eq!(parsed.tailnet, None);
        parsed.mac_key = LanIdentity::generate().public_b64();
        let mac = LanMac::from_reply(&parsed).unwrap();
        assert!(mac.tailnet.is_empty());
        assert_eq!(mac.candidates_with(None, true), vec!["192.168.1.20:7421".parse::<SocketAddr>().unwrap()]);
    }

    #[test]
    fn an_old_phone_ignores_a_new_macs_tailnet_hint() {
        let new_mac = reply(tailnet_hint(true, &["100.101.102.103".parse().unwrap()]));
        let text = serde_json::to_string(&new_mac).unwrap();
        assert!(text.contains(r#""tailnet":{"v":1,"addresses":["100.101.102.103"]}"#), "{text}");
        let old: OldReply = serde_json::from_str(&text).unwrap();
        assert_eq!(old.addresses, vec!["192.168.1.20".to_owned()]);
        assert_eq!(serde_json::from_str::<LanEnrollReply>(&text).unwrap(), new_mac);
    }

    #[test]
    fn a_mac_with_its_setting_off_sends_no_hint() {
        let ip: IpAddr = "100.101.102.103".parse().unwrap();
        assert_eq!(tailnet_hint(false, &[ip]), None);
        assert_eq!(tailnet_hint(true, &[]), None);
        assert_eq!(tailnet_hint(true, &["192.168.1.2".parse().unwrap()]), None, "not a tailnet address");
        let text = serde_json::to_string(&reply(None)).unwrap();
        assert!(!text.contains("tailnet"), "an off Mac's reply is byte-for-byte the old shape: {text}");
    }

    #[test]
    fn the_phone_races_a_tailnet_address_only_with_its_setting_on() {
        let hint = TailnetHint {
            v: TAILNET_HINT_VERSION,
            addresses: vec!["100.101.102.103".into(), "8.8.8.8".into(), "fd7a:115c:a1e0::1".into()],
        };
        let mac = LanMac::from_reply(&reply(Some(hint))).unwrap();
        assert_eq!(mac.tailnet, vec!["100.101.102.103".to_owned()], "only tailnet IPv4 is kept");
        let lan: SocketAddr = "192.168.1.20:7421".parse().unwrap();
        let tailnet: SocketAddr = "100.101.102.103:7421".parse().unwrap();
        assert_eq!(mac.candidates_with(None, false), vec![lan]);
        assert_eq!(mac.candidates_with(None, true), vec![lan, tailnet], "LAN first, then tailnet");
        assert_eq!(mac.candidates(None), vec![lan], "the old call is unchanged");
    }

    #[test]
    fn a_tailnet_address_that_worked_leads_only_while_the_setting_is_on() {
        let hint = TailnetHint { v: TAILNET_HINT_VERSION, addresses: vec!["100.101.102.103".into()] };
        let mut mac = LanMac::from_reply(&reply(Some(hint))).unwrap();
        mac.last_ok.insert("10.0.0.0/24".into(), "100.101.102.103:7421".into());
        let lan: SocketAddr = "192.168.1.20:7421".parse().unwrap();
        let tailnet: SocketAddr = "100.101.102.103:7421".parse().unwrap();
        assert_eq!(mac.candidates_with(Some("10.0.0.0/24"), true), vec![tailnet, lan]);
        assert_eq!(mac.candidates_with(Some("10.0.0.0/24"), false), vec![lan], "off: no tailnet at all");
    }

    #[test]
    fn a_hint_of_an_unknown_version_is_ignored() {
        let hint = TailnetHint { v: TAILNET_HINT_VERSION + 1, addresses: vec!["100.101.102.103".into()] };
        let mac = LanMac::from_reply(&reply(Some(hint))).unwrap();
        assert!(mac.tailnet.is_empty());
    }

    #[test]
    fn memory_written_before_t5_still_loads() {
        let old = r#"{"macKey":"K","port":7421,"phoneOverlay":"10.78.0.2","addresses":["192.168.1.20"]}"#;
        let mac: LanMac = serde_json::from_str(old).unwrap();
        assert!(mac.tailnet.is_empty());
    }

    #[test]
    fn overlay_addresses_are_unique_and_skip_the_mac() {
        let mut phones = Vec::new();
        for n in 0..3 {
            let overlay = free_overlay(&phones).unwrap();
            assert_ne!(overlay, MAC_OVERLAY);
            phones.push(EnrolledPhone { device_id: format!("p{n}"), key: String::new(), overlay });
        }
        assert_eq!(phones[2].overlay, Ipv4Addr::new(10, 78, 0, 4));
    }

    #[test]
    fn only_private_ipv4_counts_as_lan() {
        assert!(lan_address("192.168.1.2".parse().unwrap(), false));
        assert!(lan_address("10.1.2.3".parse().unwrap(), false));
        assert!(!lan_address("100.100.1.1".parse().unwrap(), false));
        assert!(!lan_address("8.8.8.8".parse().unwrap(), false));
        assert!(!lan_address("127.0.0.1".parse().unwrap(), false));
        assert!(lan_address("127.0.0.1".parse().unwrap(), true));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_enrolled_phone_reaches_the_mac_and_a_stranger_does_not() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let host = LanHost::start(LanIdentity::generate(), 0, None, true).await.unwrap();
        let phone = LanIdentity::generate();
        let reply =
            host.enroll("phone-1", &LanEnrollRequest { phone_key: phone.public_b64() }).await.unwrap();
        let mac = LanMac::from_reply(&reply).unwrap();
        let target: SocketAddr = (Ipv4Addr::LOCALHOST, host.port()).into();
        let timeline = crate::Timeline::default();

        let dialed = dial(&phone, &mac, vec![target], &timeline).await.unwrap();
        assert_eq!(dialed.address, target);
        let mut accepted =
            tokio::time::timeout(Duration::from_secs(5), host.accept()).await.unwrap().unwrap();
        assert_eq!(accepted.device_id, "phone-1");
        let mut phone_stream = dialed.dialed.stream;
        phone_stream.write_all(b"ping").await.unwrap();
        let mut buf = [0u8; 4];
        accepted.dialed.stream.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"ping");
        accepted.dialed.stream.write_all(b"pong").await.unwrap();
        phone_stream.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"pong");
        // The input lane pairs with its link by key.
        let lane = tokio::time::timeout(Duration::from_secs(5), accepted.dialed.lane.take().unwrap()).await;
        assert!(matches!(lane, Ok(Ok(_))));

        // A key the Mac never enrolled gets no answer.
        let stranger = LanIdentity::generate();
        let refused = dial(&stranger, &mac, vec![target], &timeline).await;
        assert!(refused.is_err());

        // Removing the phone closes the door for its key.
        host.remove("phone-1").await;
        assert!(dial(&phone, &mac, vec![target], &timeline).await.is_err());
    }

    /// Someone on the LAN who recorded an enrolled phone's packets (its
    /// handshake and data) and sends them again gets nothing: the Mac answers
    /// no replayed datagram and opens no link for it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_replayed_session_gets_no_answer_and_no_link() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::UdpSocket;
        let host = LanHost::start(LanIdentity::generate(), 0, None, true).await.unwrap();
        let phone = LanIdentity::generate();
        let reply =
            host.enroll("phone-1", &LanEnrollRequest { phone_key: phone.public_b64() }).await.unwrap();
        let mac = LanMac::from_reply(&reply).unwrap();
        let target: SocketAddr = (Ipv4Addr::LOCALHOST, host.port()).into();

        // A tap between phone and Mac that keeps a copy of every phone datagram.
        let front = Arc::new(UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap());
        let back = Arc::new(UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap());
        back.connect(target).await.unwrap();
        let recorded = Arc::new(std::sync::Mutex::new(Vec::<Vec<u8>>::new()));
        let phone_addr = Arc::new(std::sync::Mutex::new(None::<SocketAddr>));
        let tap_up = {
            let (front, back, recorded, phone_addr) =
                (Arc::clone(&front), Arc::clone(&back), Arc::clone(&recorded), Arc::clone(&phone_addr));
            tokio::spawn(async move {
                let mut buf = vec![0u8; 65536];
                while let Ok((n, from)) = front.recv_from(&mut buf).await {
                    *phone_addr.lock().unwrap() = Some(from);
                    recorded.lock().unwrap().push(buf[..n].to_vec());
                    let _ = back.send(&buf[..n]).await;
                }
            })
        };
        let tap_down = {
            let (front, back, phone_addr) = (Arc::clone(&front), Arc::clone(&back), Arc::clone(&phone_addr));
            tokio::spawn(async move {
                let mut buf = vec![0u8; 65536];
                while let Ok(n) = back.recv(&mut buf).await {
                    let to = *phone_addr.lock().unwrap();
                    if let Some(to) = to {
                        let _ = front.send_to(&buf[..n], to).await;
                    }
                }
            })
        };

        let timeline = crate::Timeline::default();
        let dialed = dial(&phone, &mac, vec![front.local_addr().unwrap()], &timeline).await.unwrap();
        let mut accepted =
            tokio::time::timeout(Duration::from_secs(5), host.accept()).await.unwrap().unwrap();
        let mut phone_stream = dialed.dialed.stream;
        phone_stream.write_all(b"ping").await.unwrap();
        let mut buf = [0u8; 4];
        accepted.dialed.stream.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"ping");
        tap_up.abort();
        tap_down.abort();
        let packets = recorded.lock().unwrap().clone();
        assert!(packets.len() >= 2, "the tap saw the handshake and data ({} datagrams)", packets.len());
        // Wait out the input lane's own accept, so the next `accept` can only
        // be a replayed link.
        drop(accepted);

        // The replay, from a socket of its own, as an attacker on the LAN would.
        let replayer = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        replayer.connect(target).await.unwrap();
        for packet in &packets {
            replayer.send(packet).await.unwrap();
        }
        let mut answer = vec![0u8; 65536];
        let answered = tokio::time::timeout(Duration::from_secs(2), replayer.recv(&mut answer)).await;
        assert!(answered.is_err(), "the Mac answered a replayed datagram");
        let link = tokio::time::timeout(Duration::from_secs(1), host.accept()).await;
        assert!(link.is_err(), "the Mac opened a link for a replayed session");
    }
}
