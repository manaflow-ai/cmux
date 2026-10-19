//! WebRTC media over the tailnet without an OS tailnet interface.
//!
//! A host with embedded Tailscale only (tsnet, a userspace network stack)
//! has no tailnet address that libwebrtc's ICE can bind, so ICE alone never
//! finds a tailnet path. This module runs a TURN server (webrtc-rs `turn`,
//! MIT OR Apache-2.0) on one tailnet TCP port of the node: the viewer's
//! unchanged libwebrtc reaches it as `turn:<host>:4181?transport=tcp`
//! (through its own tsnet node and a loopback forward, or directly when the
//! viewer has the Tailscale app), and the relay sends the media as UDP to the
//! host's own libwebrtc host candidates on this machine.
//!
//! Path: viewer libwebrtc -> TCP (TURN framing) -> tailnet (WireGuard) ->
//! this listener -> relay UDP socket -> host libwebrtc on the same machine.
//! The tailnet leg is TCP, so the 1280-byte tailnet MTU never limits RTP
//! (TCP segments it); the cost is head-of-line blocking on loss.
//!
//! Gates, in order, for each TCP connection:
//! 1. the node listens on its tailnet addresses only;
//! 2. WhoIs on the peer address, then [`Access`] (the same rule as signaling);
//! 3. TURN long-term credentials that exist only as a [`TurnGrant`] the host
//!    minted for one signaling link, bound to that link's device (WhoIs
//!    node), and at most [`MAX_CONNECTIONS_PER_GRANT`] connections each;
//!    a connection that does not authenticate in 10 s is dropped;
//! 4. the relay sends only to the exact host candidates the host added with
//!    [`TurnGrant::allow_peer`], never to any other address (no open relay
//!    into the host's LAN or its local services).
//!
//! A grant ends when its last holder drops it (the signaling link and the
//! WebRTC session each hold one): its TCP connections close and their
//! allocations are deleted at once.

use std::collections::{HashMap, HashSet};
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio_util::sync::CancellationToken;
use turn::auth::{AuthHandler, generate_auth_key};
use turn::relay::RelayAddressGenerator;
use turn::server::Server;
use turn::server::config::{ConnConfig, ServerConfig};
use webrtc_util::Conn;

use crate::{Access, Decision, Error, Node, Result};

/// The default tailnet port of the relay (signaling is 4180).
pub const DEFAULT_RELAY_PORT: u16 = 4181;
/// TURN realm of every grant.
pub const REALM: &str = "cmux";
/// A connection must authenticate within this time.
const AUTH_DEADLINE: Duration = Duration::from_secs(10);
/// libwebrtc opens one TURN connection per local network; more than this is not a viewer.
pub const MAX_CONNECTIONS_PER_GRANT: usize = 8;
/// The largest STUN or ChannelData frame passed to the TURN server (its read buffer).
const MAX_FRAME: usize = 1500;

/// Where log lines go (the host passes its own timestamped logger).
pub type Log = Arc<dyn Fn(&str) + Send + Sync>;

#[derive(Default)]
struct Registry {
    grants: Mutex<HashMap<String, Weak<TurnGrant>>>,
}

/// The relay on one tailnet port. Mint a [`TurnGrant`] per viewer link.
pub struct TurnRelay {
    registry: Arc<Registry>,
    port: u16,
}

/// TURN credentials for one viewer link. The relay accepts them while any
/// `Arc<TurnGrant>` lives; dropping the last one revokes them and closes
/// every connection that used them.
pub struct TurnGrant {
    username: String,
    password: String,
    /// The WhoIs node (stable id) that may use these credentials; None: any admitted node (CLI check only).
    node: Option<String>,
    /// The host's own candidates the relay may send to.
    peers: Mutex<HashSet<SocketAddr>>,
    connections: AtomicUsize,
    revoked: CancellationToken,
    registry: Weak<Registry>,
}

impl TurnGrant {
    pub fn username(&self) -> &str {
        &self.username
    }

    pub fn password(&self) -> &str {
        &self.password
    }

    /// Lets the relay send to `addr`, one of the host's own ICE host candidates.
    pub fn allow_peer(&self, addr: SocketAddr) {
        self.peers.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).insert(addr);
    }

    /// Forgets every allowed peer (a new session on the same link gathers new candidates).
    pub fn clear_peers(&self) {
        self.peers.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clear();
    }

    fn allows(&self, addr: &SocketAddr) -> bool {
        self.peers.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).contains(addr)
    }

    fn allows_source(&self, ip: IpAddr) -> bool {
        self.peers.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).iter().any(|peer| peer.ip() == ip)
    }
}

impl Drop for TurnGrant {
    fn drop(&mut self) {
        self.revoked.cancel();
        if let Some(registry) = self.registry.upgrade() {
            registry.grants.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(&self.username);
        }
    }
}

impl TurnRelay {
    /// Listens on tailnet `port` and serves TURN-over-TCP to admitted peers.
    /// Connections run on `runtime`; accept and WhoIs run on their own thread.
    pub fn serve(node: Arc<Node>, access: Access, port: u16, runtime: tokio::runtime::Handle, log: Log) -> Result<Arc<Self>> {
        let listener = node.listen_tcp(port)?;
        let relay = Arc::new(Self { registry: Arc::new(Registry::default()), port });
        let registry = relay.registry.clone();
        std::thread::Builder::new()
            .name("tailnet-turn-accept".into())
            .spawn(move || {
                loop {
                    let (stream, remote) = match listener.accept() {
                        Ok(accepted) => accepted,
                        Err(error) if error.0 == "listener closed" => {
                            log("turn relay: listener closed");
                            return;
                        }
                        Err(error) => {
                            log(&format!("turn relay: accept: {error}"));
                            continue;
                        }
                    };
                    let checked = node.whois(&remote).and_then(|peer| Ok((access.check(&node.status()?, &peer), peer)));
                    let peer_node = match checked {
                        Ok((Decision::Allow { .. }, peer)) => match peer.node.map(|node| node.stable_id).filter(|id| !id.is_empty()) {
                            Some(id) => id,
                            None => {
                                log(&format!("turn relay: {remote} refused, no node identity"));
                                continue;
                            }
                        },
                        Ok((Decision::Deny { principal, why }, _)) => {
                            log(&format!("turn relay: {remote} ({principal}) refused, {why}"));
                            continue;
                        }
                        Err(error) => {
                            log(&format!("turn relay: {remote} refused, no identity ({error})"));
                            continue;
                        }
                    };
                    let (registry, log) = (registry.clone(), log.clone());
                    runtime.spawn(async move {
                        if let Err(error) = serve_connection(stream, &remote, peer_node, registry).await {
                            log(&format!("turn relay: {remote}: {error}"));
                        }
                    });
                }
            })
            .map_err(|error| Error(format!("turn relay thread: {error}")))?;
        Ok(relay)
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// New random credentials for the device `node` (WhoIs stable id).
    /// `None` accepts any admitted device: only for the CLI check.
    pub fn grant(&self, node: Option<String>) -> Result<Arc<TurnGrant>> {
        let mut user = [0u8; 12];
        let mut pass = [0u8; 24];
        getrandom::getrandom(&mut user).and_then(|()| getrandom::getrandom(&mut pass)).map_err(|error| Error(format!("random: {error}")))?;
        let grant = Arc::new(TurnGrant {
            username: URL_SAFE_NO_PAD.encode(user),
            password: URL_SAFE_NO_PAD.encode(pass),
            node,
            peers: Mutex::new(HashSet::new()),
            connections: AtomicUsize::new(0),
            revoked: CancellationToken::new(),
            registry: Arc::downgrade(&self.registry),
        });
        self.registry
            .grants
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(grant.username.clone(), Arc::downgrade(&grant));
        Ok(grant)
    }

    /// The ICE server URL for this relay on `node`: its tailnet IPv4, else its MagicDNS name.
    pub fn ice_url(&self, node: &Node) -> Option<String> {
        let ips = node.ips().ok()?;
        let host = match ips.iter().find(|ip| ip.parse::<Ipv4Addr>().is_ok()) {
            Some(ip) => ip.clone(),
            None => node.status().ok()?.dns_name()?,
        };
        Some(format!("turn:{host}:{}?transport=tcp", self.port))
    }
}

/// One admitted TCP connection: its own TURN server instance, so its
/// allocations end with it.
async fn serve_connection(stream: UnixStream, remote: &str, peer_node: String, registry: Arc<Registry>) -> Result<()> {
    let error = |error: &dyn std::fmt::Display| Error(error.to_string());
    stream.set_nonblocking(true).map_err(|e| error(&e))?;
    let stream = tokio::net::UnixStream::from_std(stream).map_err(|e| error(&e))?;
    let (read, write) = stream.into_split();
    let remote_addr = parse_remote(remote);
    let stop = CancellationToken::new();
    let local = SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0));
    let conn = Arc::new(StreamConn::new(Box::new(read), Box::new(write), local, remote_addr, stop.clone()));
    let auth = Arc::new(ConnAuth { registry, peer_node, bound: Mutex::new(None), bound_signal: tokio::sync::Notify::new() });
    let server = Server::new(ServerConfig {
        conn_configs: vec![ConnConfig {
            conn,
            relay_addr_generator: Box::new(LocalRelay { auth: auth.clone(), advertised: primary_ipv4() }),
        }],
        realm: REALM.into(),
        auth_handler: auth.clone(),
        channel_bind_timeout: Duration::ZERO,
        alloc_close_notify: None,
    })
    .await
    .map_err(|e| error(&e))?;
    let revoked = tokio::select! {
        _ = stop.cancelled() => None,
        _ = auth.bound_signal.notified() => auth.revoked(),
        // An authentication deadline, not synchronization.
        _ = tokio::time::sleep(AUTH_DEADLINE) => auth.revoked(),
    };
    if let Some(revoked) = revoked {
        tokio::select! {
            _ = stop.cancelled() => {}
            _ = revoked.cancelled() => {}
        }
    }
    stop.cancel();
    let _ = server.close().await;
    Ok(())
}

fn parse_remote(remote: &str) -> SocketAddr {
    remote
        .parse::<SocketAddr>()
        .ok()
        .or_else(|| {
            let ip = remote.strip_prefix('[').and_then(|ip| ip.strip_suffix(']')).unwrap_or(remote);
            ip.parse::<IpAddr>().ok().map(|ip| SocketAddr::new(ip, 0))
        })
        .unwrap_or_else(|| SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0)))
}

/// The IPv4 address this machine uses toward the default route (no packet is
/// sent), else loopback. Reported as the relay address; the relay socket
/// itself listens on every local address.
fn primary_ipv4() -> IpAddr {
    std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))
        .and_then(|socket| socket.connect((Ipv4Addr::new(192, 0, 2, 1), 9)).map(|()| socket))
        .and_then(|socket| socket.local_addr())
        .map(|addr| addr.ip())
        .ok()
        .filter(|ip| !ip.is_unspecified())
        .unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST))
}

struct Bound {
    username: String,
    grant: Weak<TurnGrant>,
    revoked: CancellationToken,
}

/// The TURN credential check of one connection: the first valid username
/// binds the connection to that grant; any other username is refused.
struct ConnAuth {
    registry: Arc<Registry>,
    peer_node: String,
    bound: Mutex<Option<Bound>>,
    bound_signal: tokio::sync::Notify,
}

impl ConnAuth {
    fn revoked(&self) -> Option<CancellationToken> {
        self.bound.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).as_ref().map(|bound| bound.revoked.clone())
    }

    fn grant(&self) -> Option<Arc<TurnGrant>> {
        self.bound.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).as_ref().and_then(|bound| bound.grant.upgrade())
    }
}

impl AuthHandler for ConnAuth {
    fn auth_handle(&self, username: &str, realm: &str, _src: SocketAddr) -> std::result::Result<Vec<u8>, turn::Error> {
        let refuse = |why: &str| Err(turn::Error::Other(why.into()));
        if realm != REALM {
            return refuse("wrong realm");
        }
        let mut bound = self.bound.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(bound) = bound.as_ref() {
            if bound.username != username {
                return refuse("connection is bound to other credentials");
            }
            return match bound.grant.upgrade() {
                Some(grant) => Ok(generate_auth_key(username, REALM, &grant.password)),
                None => refuse("credentials revoked"),
            };
        }
        let grant = self.registry.grants.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).get(username).and_then(Weak::upgrade);
        let Some(grant) = grant else { return refuse("unknown credentials") };
        if grant.node.as_ref().is_some_and(|node| *node != self.peer_node) {
            return refuse("credentials belong to another device");
        }
        if grant.connections.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS_PER_GRANT {
            grant.connections.fetch_sub(1, Ordering::SeqCst);
            return refuse("too many connections");
        }
        *bound = Some(Bound { username: username.to_owned(), grant: Arc::downgrade(&grant), revoked: grant.revoked.clone() });
        self.bound_signal.notify_one();
        Ok(generate_auth_key(username, REALM, &grant.password))
    }
}

impl Drop for ConnAuth {
    fn drop(&mut self) {
        if let Some(grant) = self.grant() {
            grant.connections.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

/// Allocates relays as UDP sockets on this machine that talk only to the grant's peers.
struct LocalRelay {
    auth: Arc<ConnAuth>,
    advertised: IpAddr,
}

#[async_trait]
impl RelayAddressGenerator for LocalRelay {
    fn validate(&self) -> std::result::Result<(), turn::Error> {
        Ok(())
    }

    async fn allocate_conn(&self, use_ipv4: bool, requested_port: u16) -> std::result::Result<(Arc<dyn Conn + Send + Sync>, SocketAddr), turn::Error> {
        if !use_ipv4 {
            return Err(turn::Error::Other("IPv4 relays only".into()));
        }
        let socket = tokio::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, requested_port))
            .await
            .map_err(|error| turn::Error::Other(error.to_string()))?;
        let mut relayed = socket.local_addr().map_err(|error| turn::Error::Other(error.to_string()))?;
        relayed.set_ip(self.advertised);
        Ok((Arc::new(GuardedRelay { socket, auth: self.auth.clone() }), relayed))
    }
}

/// A relay socket that sends only to the grant's peers and drops datagrams from anyone else.
struct GuardedRelay {
    socket: tokio::net::UdpSocket,
    auth: Arc<ConnAuth>,
}

fn refused(why: &str) -> webrtc_util::Error {
    webrtc_util::Error::Other(why.into())
}

#[async_trait]
impl Conn for GuardedRelay {
    async fn connect(&self, _addr: SocketAddr) -> webrtc_util::Result<()> {
        Err(refused("relay sockets do not connect"))
    }

    async fn recv(&self, buf: &mut [u8]) -> webrtc_util::Result<usize> {
        Ok(self.recv_from(buf).await?.0)
    }

    async fn recv_from(&self, buf: &mut [u8]) -> webrtc_util::Result<(usize, SocketAddr)> {
        loop {
            let (n, from) = self.socket.recv_from(buf).await?;
            if self.auth.grant().is_some_and(|grant| grant.allows_source(from.ip())) {
                return Ok((n, from));
            }
        }
    }

    async fn send(&self, _buf: &[u8]) -> webrtc_util::Result<usize> {
        Err(refused("relay sockets send to a peer"))
    }

    async fn send_to(&self, buf: &[u8], target: SocketAddr) -> webrtc_util::Result<usize> {
        if !self.auth.grant().is_some_and(|grant| grant.allows(&target)) {
            return Err(refused("peer is not one of the host's candidates"));
        }
        Ok(self.socket.send_to(buf, target).await?)
    }

    fn local_addr(&self) -> webrtc_util::Result<SocketAddr> {
        Ok(self.socket.local_addr()?)
    }

    fn remote_addr(&self) -> Option<SocketAddr> {
        None
    }

    async fn close(&self) -> webrtc_util::Result<()> {
        Ok(())
    }

    fn as_any(&self) -> &(dyn std::any::Any + Send + Sync) {
        self
    }
}

type Reader = Box<dyn AsyncRead + Send + Unpin>;
type Writer = Box<dyn AsyncWrite + Send + Unpin>;

/// A TURN-over-TCP stream as the packet `Conn` the `turn` crate expects:
/// one STUN message or ChannelData frame per datagram (RFC 8656 section 12.5:
/// on TCP, ChannelData is padded to a multiple of 4 bytes).
struct StreamConn {
    read: tokio::sync::Mutex<Reader>,
    write: tokio::sync::Mutex<Writer>,
    local: SocketAddr,
    remote: SocketAddr,
    stop: CancellationToken,
}

impl StreamConn {
    fn new(read: Reader, write: Writer, local: SocketAddr, remote: SocketAddr, stop: CancellationToken) -> Self {
        Self { read: tokio::sync::Mutex::new(read), write: tokio::sync::Mutex::new(write), local, remote, stop }
    }
}

async fn read_frame(read: &mut Reader) -> io::Result<Vec<u8>> {
    let mut head = [0u8; 4];
    read.read_exact(&mut head).await?;
    let length = u16::from_be_bytes([head[2], head[3]]) as usize;
    let (total, padding) = match head[0] >> 6 {
        0 => (20 + length, 0),
        1 => (4 + length, (4 - length % 4) % 4),
        _ => return Err(io::Error::new(io::ErrorKind::InvalidData, "not STUN or ChannelData")),
    };
    let mut frame = vec![0u8; total];
    frame[..4].copy_from_slice(&head);
    read.read_exact(&mut frame[4..]).await?;
    if padding > 0 {
        let mut skip = [0u8; 3];
        read.read_exact(&mut skip[..padding]).await?;
    }
    Ok(frame)
}

#[async_trait]
impl Conn for StreamConn {
    async fn connect(&self, _addr: SocketAddr) -> webrtc_util::Result<()> {
        Ok(())
    }

    async fn recv(&self, buf: &mut [u8]) -> webrtc_util::Result<usize> {
        Ok(self.recv_from(buf).await?.0)
    }

    async fn recv_from(&self, buf: &mut [u8]) -> webrtc_util::Result<(usize, SocketAddr)> {
        let mut read = self.read.lock().await;
        loop {
            let frame = tokio::select! {
                _ = self.stop.cancelled() => return Err(refused("connection closed")),
                frame = read_frame(&mut read) => frame,
            };
            match frame {
                // Larger than the TURN server reads: not media from libwebrtc; skip it.
                Ok(frame) if frame.len() > buf.len() => continue,
                Ok(frame) => {
                    buf[..frame.len()].copy_from_slice(&frame);
                    return Ok((frame.len(), self.remote));
                }
                Err(error) => {
                    self.stop.cancel();
                    return Err(error.into());
                }
            }
        }
    }

    async fn send(&self, buf: &[u8]) -> webrtc_util::Result<usize> {
        self.send_to(buf, self.remote).await
    }

    async fn send_to(&self, buf: &[u8], _target: SocketAddr) -> webrtc_util::Result<usize> {
        let padding = if buf.first().is_some_and(|byte| byte >> 6 == 1) { (4 - buf.len() % 4) % 4 } else { 0 };
        let mut write = self.write.lock().await;
        let written = async {
            write.write_all(buf).await?;
            write.write_all(&[0u8; 3][..padding]).await
        };
        let result = tokio::select! {
            _ = self.stop.cancelled() => return Err(refused("connection closed")),
            result = written => result,
        };
        if let Err(error) = result {
            self.stop.cancel();
            return Err(error.into());
        }
        Ok(buf.len())
    }

    fn local_addr(&self) -> webrtc_util::Result<SocketAddr> {
        Ok(self.local)
    }

    fn remote_addr(&self) -> Option<SocketAddr> {
        Some(self.remote)
    }

    async fn close(&self) -> webrtc_util::Result<()> {
        self.stop.cancel();
        Ok(())
    }

    fn as_any(&self) -> &(dyn std::any::Any + Send + Sync) {
        self
    }
}

/// What [`probe`] measured.
pub struct Probe {
    pub relayed: SocketAddr,
    pub echoed: usize,
    pub round_trip: Duration,
}

/// An end-to-end check of a relay: a TURN client over TCP at `via` (the
/// relay port, or a loopback forward to it) allocates, sends one datagram
/// through the relay to `peer` (a UDP echo the host allowed), and waits up
/// to 5 s for the echo.
pub async fn probe(via: SocketAddr, username: &str, password: &str, peer: SocketAddr) -> Result<Probe> {
    let error = |error: &dyn std::fmt::Display| Error(error.to_string());
    let stream = tokio::net::TcpStream::connect(via).await.map_err(|e| error(&e))?;
    stream.set_nodelay(true).map_err(|e| error(&e))?;
    let local = stream.local_addr().map_err(|e| error(&e))?;
    let (read, write) = stream.into_split();
    let conn = Arc::new(StreamConn::new(Box::new(read), Box::new(write), local, via, CancellationToken::new()));
    let client = turn::client::Client::new(turn::client::ClientConfig {
        stun_serv_addr: String::new(),
        turn_serv_addr: via.to_string(),
        username: username.into(),
        password: password.into(),
        realm: REALM.into(),
        software: "cmux-tailnet turn-check".into(),
        rto_in_ms: 0,
        conn: conn.clone(),
        vnet: None,
    })
    .await
    .map_err(|e| error(&e))?;
    client.listen().await.map_err(|e| error(&e))?;
    let checked = async {
        let relay = client.allocate().await.map_err(|e| error(&e))?;
        let relayed = relay.local_addr().map_err(|e| error(&e))?;
        let started = Instant::now();
        relay.send_to(b"cmux turn check", peer).await.map_err(|e| error(&e))?;
        let mut buf = [0u8; MAX_FRAME];
        let (echoed, _) = tokio::time::timeout(Duration::from_secs(5), relay.recv_from(&mut buf))
            .await
            .map_err(|_| Error("no echo through the relay in 5 s".into()))?
            .map_err(|e| error(&e))?;
        let round_trip = started.elapsed();
        let _ = relay.close().await;
        Ok(Probe { relayed, echoed, round_trip })
    }
    .await;
    let _ = client.close().await;
    let _ = conn.close().await;
    checked
}
