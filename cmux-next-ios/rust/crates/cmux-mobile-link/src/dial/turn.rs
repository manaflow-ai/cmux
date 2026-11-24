//! TURN allocations as WireGuard carriers (PROTOCOL.md "WireGuard over
//! TURN").
//!
//! The allocation always relays UDP to the peer; only the leg between this
//! side and the TURN server changes:
//!
//! - UDP (`turn:host:port?transport=udp`), tried first;
//! - TLS (`turns:host:443?transport=tcp`, RFC 5766 §2.1 over TLS), when UDP
//!   gets no allocation: networks that block UDP almost always pass TLS on
//!   443. Plain TCP (`turn:...?transport=tcp`) is the last choice.
//!
//! Over TCP and TLS every STUN message and ChannelData message is framed
//! by its own length (RFC 5766 §11.5, ChannelData padded to 4 bytes), so
//! [`StreamConn`] turns the stream back into the messages the `turn` crate's
//! client expects from a packet socket. Datagrams queue by class
//! ([`crate::class_queue`]) in front of the allocation, so on a backed-up
//! stream control and input still go first and stale video is dropped.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use bytes::Bytes;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadHalf, WriteHalf};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use webrtc::util::Conn;

use super::DialOptions;
use crate::api::IceServer;
use crate::class_queue::{ClassQueue, Queued, SendClass};

/// Bound on a UDP allocation; the dial goes on without one after this.
const UDP_WAIT: Duration = Duration::from_millis(2000);
/// Bound on a UDP allocation when no TCP or TLS TURN server is listed, so
/// there is nothing to hand a slow one over to. A lost answer or two on a
/// lossy link takes it past `UDP_WAIT`: the longest of 80 lossy-3 dials in
/// `lan_roundtrip` (idle and under load) took 2211 ms, through the 437
/// release. Past this, the dial goes on without a relay instead of waiting
/// out the turn crate's 7 sends (7.8 s).
const NO_STREAM_UDP_WAIT: Duration = Duration::from_millis(3000);
/// A stream allocation starts this long after the UDP one, unless UDP
/// failed sooner: UDP to the nearest TURN server takes two round trips
/// where it works, so a network that answers UDP never opens a TLS
/// connection it does not need. A dial starts it at once instead (relay
/// first): it pays one TLS connection, dropped when UDP wins, so that a
/// network that drops UDP is not held for the stagger.
const STREAM_STAGGER: Duration = Duration::from_millis(500);
/// Bound on a stream allocation (TCP, TLS and two TURN round trips).
const STREAM_WAIT: Duration = Duration::from_millis(4000);
/// When the stream allocation finished first, UDP gets this much longer.
const UDP_GRACE: Duration = Duration::from_millis(250);
/// STUN retransmission timeout on a stream: TCP already retransmits, so
/// a request is repeated only when the server truly did not answer.
const STREAM_RTO_MS: u16 = 1500;
/// Datagrams received from the TURN server before new ones are dropped.
const INBOUND_QUEUE: usize = 1024;
/// Bound on the TCP connect and TLS handshake to a TURN server.
const CONNECT_WAIT: Duration = Duration::from_secs(10);
/// A write to the TURN stream that takes longer than this means the stream
/// is stuck (a middlebox that black-holes it without a reset): it is dead.
const STREAM_WRITE_WAIT: Duration = Duration::from_secs(10);
/// TCP keepalive on the TURN stream, so a silent dead connection is noticed.
const STREAM_KEEPALIVE: Duration = Duration::from_secs(10);
/// A peer address the allocation could not send to (say a refused
/// permission) is skipped this long, so it does not stall the queue.
const FAILED_TARGET_WAIT: Duration = Duration::from_secs(5);
/// The largest STUN or ChannelData message on a stream (RFC 5766: 16-bit
/// length) with its header and padding.
#[cfg(test)]
const MAX_MESSAGE: usize = 20 + 65_535 + 3;

/// How this side reaches its TURN server.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnTransport {
    Udp,
    Tcp,
    Tls,
}

impl TurnTransport {
    /// Whether the leg to the server is a stream (the path `turn-tls`).
    pub fn is_stream(self) -> bool {
        self != Self::Udp
    }
}

/// One TURN server from `/v1/ice`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnServer {
    /// `host:port` to connect to.
    pub address: String,
    /// The host name, for TLS server name verification.
    pub host: String,
    pub transport: TurnTransport,
    pub username: String,
    pub credential: String,
}

/// `host[:port]` or `[v6][:port]` → `(host, port)`.
fn split_host_port(text: &str, default_port: u16) -> Option<(String, u16)> {
    if let Some(rest) = text.strip_prefix('[') {
        let (host, after) = rest.split_once(']')?;
        let port = match after.strip_prefix(':') {
            Some(port) => port.parse().ok()?,
            None if after.is_empty() => default_port,
            None => return None,
        };
        return Some((host.to_owned(), port));
    }
    match text.rsplit_once(':') {
        Some((host, port)) => Some((host.to_owned(), port.parse().ok()?)),
        None => Some((text.to_owned(), default_port)),
    }
}

fn parse_url(url: &str, username: &str, credential: &str) -> Option<TurnServer> {
    let (secure, rest) = if let Some(rest) = url.strip_prefix("turns:") {
        (true, rest)
    } else {
        (false, url.strip_prefix("turn:")?)
    };
    let (host_port, query) = rest.split_once('?').unwrap_or((rest, ""));
    let wanted = query.split('&').find_map(|pair| pair.strip_prefix("transport="));
    let transport = match (secure, wanted) {
        (true, None | Some("tcp")) => TurnTransport::Tls,
        (false, None | Some("udp")) => TurnTransport::Udp,
        (false, Some("tcp")) => TurnTransport::Tcp,
        _ => return None,
    };
    let (host, port) = split_host_port(host_port, if secure { 5349 } else { 3478 })?;
    if host.is_empty() {
        return None;
    }
    let address = if host.contains(':') { format!("[{host}]:{port}") } else { format!("{host}:{port}") };
    Some(TurnServer {
        address,
        host,
        transport,
        username: username.to_owned(),
        credential: credential.to_owned(),
    })
}

/// The TURN servers of `servers` to try: the first one over UDP, and the
/// best one over a stream (TLS on 443, else any TLS, else plain TCP).
pub fn turn_servers(servers: &[IceServer]) -> (Option<TurnServer>, Option<TurnServer>) {
    let all = servers_in_order(servers);
    let udp = all.iter().find(|server| server.transport == TurnTransport::Udp).cloned();
    let rank = |server: &TurnServer| match server.transport {
        TurnTransport::Tls if server.address.ends_with(":443") => 0,
        TurnTransport::Tls => 1,
        TurnTransport::Tcp => 2,
        TurnTransport::Udp => 3,
    };
    let stream =
        all.iter().filter(|server| server.transport.is_stream()).min_by_key(|server| rank(server)).cloned();
    (udp, stream)
}

/// Why a WireGuard dial with these options cannot work, before it starts:
/// relay only and UDP blocked have no path but TURN.
pub fn missing_turn(options: &DialOptions) -> Option<&'static str> {
    let (udp, stream) = turn_servers(&options.ice_servers);
    if options.block_udp && stream.is_none() {
        return Some("UDP blocked needs a TURN server over TLS, and the service offered none");
    }
    if options.relay_only && udp.is_none() && stream.is_none() {
        return Some("relay only needs a TURN server, and the service offered none");
    }
    None
}

/// The TLS client configuration for TURN over TLS.
fn tls_config(options: &DialOptions) -> Result<Arc<rustls::ClientConfig>, String> {
    let roots = options.turn_tls_roots.clone().unwrap_or_else(|| {
        Arc::new(rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() })
    });
    let config =
        rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .map_err(|error| error.to_string())?
            .with_root_certificates(roots)
            .with_no_client_auth();
    Ok(Arc::new(config))
}

/// The next STUN or ChannelData message on a TURN stream, into `buffer`:
/// its length without ChannelData padding. `None` at a clean end of stream.
pub async fn read_message<R: AsyncRead + Unpin>(
    reader: &mut R,
    buffer: &mut [u8],
) -> std::io::Result<Option<usize>> {
    let mut head = [0u8; 4];
    match reader.read_exact(&mut head).await {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    let length = usize::from(u16::from_be_bytes([head[2], head[3]]));
    let (message, framed) = match head[0] >> 6 {
        // STUN: a 20-byte header; the length already counts whole words.
        0b00 => (20 + length, 20 + length),
        // ChannelData: a 4-byte header, padded to 4 bytes on a stream.
        0b01 => (4 + length, (4 + length + 3) & !3),
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "not a STUN or ChannelData message",
            ));
        }
    };
    if framed > buffer.len() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "TURN message larger than the buffer",
        ));
    }
    buffer[..4].copy_from_slice(&head);
    reader.read_exact(&mut buffer[4..framed]).await?;
    Ok(Some(message))
}

/// A TURN stream as the packet socket the `turn` crate expects: every
/// message read is "from" the other end (the server, for a client; the
/// client, for the test server), every message written goes to it. Any
/// read or write failure marks the stream dead.
pub struct StreamConn<S> {
    reader: tokio::sync::Mutex<ReadHalf<S>>,
    writer: tokio::sync::Mutex<WriteHalf<S>>,
    local: SocketAddr,
    server: SocketAddr,
    dead: watch::Sender<bool>,
    closed: AtomicBool,
}

impl<S: AsyncRead + AsyncWrite + Send + 'static> StreamConn<S> {
    pub fn new(stream: S, local: SocketAddr, server: SocketAddr) -> Self {
        let (reader, writer) = tokio::io::split(stream);
        Self {
            reader: tokio::sync::Mutex::new(reader),
            writer: tokio::sync::Mutex::new(writer),
            local,
            server,
            dead: watch::channel(false).0,
            closed: AtomicBool::new(false),
        }
    }

    /// Becomes `true` once the stream failed or ended.
    pub fn dead(&self) -> watch::Receiver<bool> {
        self.dead.subscribe()
    }

    fn fail(&self, error: std::io::Error) -> webrtc::util::Error {
        self.dead.send_replace(true);
        webrtc::util::Error::from(error)
    }
}

#[async_trait::async_trait]
impl<S: AsyncRead + AsyncWrite + Send + Sync + 'static> Conn for StreamConn<S> {
    async fn connect(&self, _addr: SocketAddr) -> webrtc::util::Result<()> {
        Ok(())
    }

    async fn recv(&self, buf: &mut [u8]) -> webrtc::util::Result<usize> {
        self.recv_from(buf).await.map(|(len, _)| len)
    }

    async fn recv_from(&self, buf: &mut [u8]) -> webrtc::util::Result<(usize, SocketAddr)> {
        let mut reader = self.reader.lock().await;
        match read_message(&mut *reader, buf).await {
            Ok(Some(len)) => Ok((len, self.server)),
            Ok(None) => {
                Err(self.fail(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "TURN stream ended")))
            }
            Err(error) => Err(self.fail(error)),
        }
    }

    async fn send(&self, buf: &[u8]) -> webrtc::util::Result<usize> {
        self.send_to(buf, self.server).await
    }

    async fn send_to(&self, buf: &[u8], _target: SocketAddr) -> webrtc::util::Result<usize> {
        if self.closed.load(Ordering::Relaxed) {
            return Err(
                self.fail(std::io::Error::new(std::io::ErrorKind::NotConnected, "TURN stream closed"))
            );
        }
        let mut writer = self.writer.lock().await;
        // The client pads ChannelData already; STUN is whole words. Flush
        // every message: TLS would otherwise keep a record until the next.
        let write = async {
            writer.write_all(buf).await?;
            writer.flush().await
        };
        match tokio::time::timeout(STREAM_WRITE_WAIT, write).await {
            Ok(Ok(())) => Ok(buf.len()),
            Ok(Err(error)) => Err(self.fail(error)),
            Err(_) => {
                Err(self.fail(std::io::Error::new(std::io::ErrorKind::TimedOut, "TURN stream write stalled")))
            }
        }
    }

    fn local_addr(&self) -> webrtc::util::Result<SocketAddr> {
        Ok(self.local)
    }

    fn remote_addr(&self) -> Option<SocketAddr> {
        Some(self.server)
    }

    async fn close(&self) -> webrtc::util::Result<()> {
        self.closed.store(true, Ordering::Relaxed);
        let _ = self.writer.lock().await.shutdown().await;
        self.dead.send_replace(true);
        Ok(())
    }

    fn as_any(&self) -> &(dyn std::any::Any + Send + Sync) {
        self
    }
}

/// A TURN allocation used as one more WireGuard carrier: the peer sends
/// plain UDP to `relayed`, and this side sends through the TURN server to
/// the peer's public endpoints.
pub struct TurnCarrier {
    pub relayed: SocketAddr,
    pub transport: TurnTransport,
    queue: Arc<ClassQueue>,
    pub inbound: mpsc::Receiver<(Bytes, SocketAddr)>,
    tasks: Vec<JoinHandle<()>>,
    relay: Arc<dyn Conn + Send + Sync>,
    client: webrtc::turn::client::Client,
    /// The socket or stream to the server.
    conn: Arc<dyn Conn + Send + Sync>,
    dead: watch::Receiver<bool>,
}

impl TurnCarrier {
    /// Allocate on the servers `options` offer: UDP first (unless UDP is
    /// blocked), then, if UDP gives nothing, a stream (TLS on 443 first).
    /// `None` when there is no server or every allocation failed in time.
    pub async fn allocate(options: &DialOptions) -> Option<Self> {
        Self::allocate_with(options, None, false).await
    }

    /// [`Self::allocate`], told by the STUN wait running beside it whether
    /// UDP looks blocked (`udp_silent` true: STUN asked, nothing came back
    /// in [`super::wireguard::STUN_SILENT`]). On such a network the stream
    /// allocation starts then instead of after its whole stagger, and UDP
    /// gets no grace once the stream is ready: waiting out UDP there held
    /// every dial on a network that drops UDP (a hotel, a guest network)
    /// about 1.5 s before TURN over TLS. `stream_now` (a dial): the stream
    /// allocation starts at once, beside UDP, instead of after its stagger.
    pub(crate) async fn allocate_with(
        options: &DialOptions,
        udp_silent: Option<watch::Receiver<bool>>,
        stream_now: bool,
    ) -> Option<Self> {
        let silent_now = || udp_silent.as_ref().is_some_and(|silent| *silent.borrow());
        let (udp, stream) = turn_servers(&options.ice_servers);
        let udp = udp.filter(|_| !options.block_udp);
        let tried_udp = udp.is_some();
        // UDP_WAIT hands a slow UDP allocation over to the stream one; with
        // no stream server there is nothing to hand over to, and UDP gets
        // NO_STREAM_UDP_WAIT (on a lossy link, losing an answer or two
        // takes it past UDP_WAIT), within the dial's own bound.
        let udp_wait =
            if stream.is_some() { UDP_WAIT } else { NO_STREAM_UDP_WAIT.min(options.timeout.max(UDP_WAIT)) };
        let udp = async {
            match udp {
                Some(server) => bounded(udp_wait, Self::allocate_on(server, options)).await,
                None => None,
            }
        };
        let stream_attempt = |delay: Duration| {
            let stream = stream.clone();
            let silent = udp_silent.clone();
            async move {
                let server = stream?;
                tokio::select! {
                    () = tokio::time::sleep(delay) => {}
                    () = until_silent(silent) => {}
                }
                bounded(STREAM_WAIT, Self::allocate_on(server, options)).await
            }
        };
        if !tried_udp {
            return stream_attempt(Duration::ZERO).await;
        }
        tokio::pin!(udp);
        let started = tokio::time::Instant::now();
        // Relay first (a dial): the stream attempt runs beside UDP from the
        // start, so a network that drops UDP has TLS ready by the time STUN
        // has been silent long enough to tell.
        let staggered = stream_attempt(if stream_now { Duration::ZERO } else { STREAM_STAGGER });
        tokio::pin!(staggered);
        tokio::select! {
            udp = &mut udp => match udp {
                Some(carrier) => Some(carrier),
                // UDP failed: the stream need not wait out its stagger, and
                // one already under way (its stagger over, or cut short
                // because UDP looked blocked) goes on.
                None if started.elapsed() >= STREAM_STAGGER || silent_now() => staggered.await,
                None => stream_attempt(Duration::ZERO).await,
            },
            stream = &mut staggered => match stream {
                // UDP looks blocked: its allocation would only run out its wait.
                Some(carrier) if silent_now() => Some(carrier),
                // UDP gets its grace, cut short once STUN has been silent.
                Some(carrier) => tokio::select! {
                    udp = tokio::time::timeout(UDP_GRACE, &mut udp) => match udp {
                        Ok(Some(udp)) => Some(udp),
                        _ => Some(carrier),
                    },
                    () = until_silent(udp_silent.clone()) => Some(carrier),
                },
                None => udp.await,
            },
        }
    }

    /// Allocate on `server` in a task of its own: a caller that gives up (a
    /// timeout, the losing side of the UDP and TLS race) drops only the
    /// answer, and the task still finishes and releases what it opened.
    async fn allocate_on(server: TurnServer, options: &DialOptions) -> Result<Self, String> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let options = options.clone();
        tokio::spawn(async move {
            let result = Self::allocate_inner(server, &options).await;
            // Unwanted by now: dropping the carrier releases the allocation.
            let _ = tx.send(result);
        });
        rx.await.map_err(|_| "the TURN allocation task ended".to_owned())?
    }

    async fn connect_stream(
        server: &TurnServer,
        options: &DialOptions,
    ) -> Result<(Arc<dyn Conn + Send + Sync>, watch::Receiver<bool>), String> {
        let tcp = TcpStream::connect(server.address.as_str()).await.map_err(|e| e.to_string())?;
        let _ = tcp.set_nodelay(true);
        let keepalive =
            socket2::TcpKeepalive::new().with_time(STREAM_KEEPALIVE).with_interval(STREAM_KEEPALIVE / 2);
        let _ = socket2::SockRef::from(&tcp).set_tcp_keepalive(&keepalive);
        let local = tcp.local_addr().map_err(|e| e.to_string())?;
        let peer = tcp.peer_addr().map_err(|e| e.to_string())?;
        if server.transport == TurnTransport::Tcp {
            let conn = StreamConn::new(tcp, local, peer);
            let dead = conn.dead();
            return Ok((Arc::new(conn), dead));
        }
        let name = rustls::pki_types::ServerName::try_from(server.host.clone()).map_err(|e| e.to_string())?;
        let tls = tokio_rustls::TlsConnector::from(tls_config(options)?)
            .connect(name, tcp)
            .await
            .map_err(|e| e.to_string())?;
        let conn = StreamConn::new(tls, local, peer);
        let dead = conn.dead();
        Ok((Arc::new(conn), dead))
    }

    async fn allocate_inner(server: TurnServer, options: &DialOptions) -> Result<Self, String> {
        let (conn, dead): (Arc<dyn Conn + Send + Sync>, Option<watch::Receiver<bool>>) = match server
            .transport
        {
            TurnTransport::Udp => (Arc::new(super::wireguard::bind_udp().map_err(|e| e.to_string())?), None),
            TurnTransport::Tcp | TurnTransport::Tls => {
                let (conn, dead) = tokio::time::timeout(CONNECT_WAIT, Self::connect_stream(&server, options))
                    .await
                    .map_err(|_| "TURN server connect timed out".to_owned())??;
                (conn, Some(dead))
            }
        };
        // The server address the client compares against: the stream's peer.
        let turn_serv_addr = match (&dead, conn.remote_addr()) {
            (Some(_), Some(peer)) => peer.to_string(),
            _ => server.address.clone(),
        };
        let config = || webrtc::turn::client::ClientConfig {
            stun_serv_addr: String::new(),
            turn_serv_addr: turn_serv_addr.clone(),
            username: server.username.clone(),
            password: server.credential.clone(),
            realm: String::new(),
            software: String::new(),
            rto_in_ms: if server.transport.is_stream() { STREAM_RTO_MS } else { 0 },
            conn: Arc::clone(&conn),
            vnet: None,
        };
        let mut client = webrtc::turn::client::Client::new(config()).await.map_err(|e| e.to_string())?;
        client.listen().await.map_err(|e| e.to_string())?;
        let mut allocated = client.allocate().await;
        // The server's answer to the Allocate was lost and the retransmit met
        // the allocation it made (437): delete that one, then allocate again
        // from the same socket. A new socket does not help where a NAT or
        // relay keeps one 5-tuple to the server.
        if server.transport == TurnTransport::Udp
            && let Err(error) = &allocated
            && is_allocation_mismatch(&error.to_string())
        {
            let _ = client.close().await;
            let released = release_allocation(&*conn, &turn_serv_addr, &server).await;
            tracing::debug!(?released, "TURN allocation already held (437): released it, allocating again");
            client = webrtc::turn::client::Client::new(config()).await.map_err(|e| e.to_string())?;
            client.listen().await.map_err(|e| e.to_string())?;
            allocated = client.allocate().await;
        }
        let relay: Arc<dyn Conn + Send + Sync> = match allocated {
            Ok(relay) => Arc::new(relay),
            Err(error) => {
                let _ = client.close().await;
                let _ = conn.close().await;
                return Err(error.to_string());
            }
        };
        let relayed = relay.local_addr().map_err(|e| e.to_string())?;
        let queue = Arc::new(ClassQueue::default());
        let (inbound_tx, inbound) = mpsc::channel(INBOUND_QUEUE);
        let sender = {
            let (relay, queue) = (Arc::clone(&relay), Arc::clone(&queue));
            tokio::spawn(async move {
                let mut failed: std::collections::HashMap<SocketAddr, tokio::time::Instant> =
                    std::collections::HashMap::new();
                while let Some(Queued { datagram, to }) = queue.next().await {
                    if failed.get(&to).is_some_and(|at| at.elapsed() < FAILED_TARGET_WAIT) {
                        continue;
                    }
                    match relay.send_to(&datagram, to).await {
                        Ok(_) => {
                            failed.remove(&to);
                        }
                        Err(error) => {
                            tracing::debug!(%error, %to, "TURN send failed; skipping this peer address for a while");
                            failed.insert(to, tokio::time::Instant::now());
                        }
                    }
                }
            })
        };
        let receiver = {
            let relay = Arc::clone(&relay);
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 65_536];
                while let Ok((len, from)) = relay.recv_from(&mut buffer).await {
                    match inbound_tx.try_send((Bytes::copy_from_slice(&buffer[..len]), from)) {
                        Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => {}
                        Err(mpsc::error::TrySendError::Closed(_)) => return,
                    }
                }
            })
        };
        let mut tasks = vec![sender, receiver];
        // A stream that dies takes the allocation with it: stop sending
        // into it (the session takes a new allocation).
        let dead = match dead {
            Some(dead) => {
                let mut watch_dead = dead.clone();
                let queue = Arc::clone(&queue);
                tasks.push(tokio::spawn(async move {
                    if watch_dead.wait_for(|dead| *dead).await.is_ok() {
                        queue.close();
                    }
                }));
                dead
            }
            None => watch::channel(false).1,
        };
        tracing::info!(%relayed, server = server.address, transport = ?server.transport, "TURN allocation for WireGuard");
        Ok(Self { relayed, transport: server.transport, queue, inbound, tasks, relay, client, conn, dead })
    }

    /// Queue one datagram to `to` through the TURN server, in `class`
    /// (dropped past its class's bound; WireGuard and TCP retransmit).
    pub fn send(&self, datagram: &[u8], to: SocketAddr, class: SendClass) {
        self.queue.push(Queued { datagram: Bytes::copy_from_slice(datagram), to }, class);
    }

    /// Whether the allocation's stream to the server failed (never for UDP).
    pub fn is_dead(&self) -> bool {
        *self.dead.borrow()
    }

    /// Becomes `true` when the allocation's stream to the server fails.
    pub fn dead(&self) -> watch::Receiver<bool> {
        self.dead.clone()
    }

    /// Debug and tests: close the connection to the server, as a middlebox
    /// that resets it would (a stream allocation then reports itself dead).
    pub fn kill(&self) {
        self.queue.close();
        let conn = Arc::clone(&self.conn);
        tokio::spawn(async move {
            let _ = conn.close().await;
        });
    }
}

/// Whether a TURN client error is a 437 (Allocation Mismatch).
fn is_allocation_mismatch(error: &str) -> bool {
    error.contains("error 437")
}

/// Retransmission timeout of [`release_allocation`]'s requests, doubled per
/// retransmit, and the requests sent per transaction.
const RELEASE_RTO: Duration = Duration::from_millis(200);
const RELEASE_SENDS: u32 = 4;

/// Delete the allocation `conn` holds on `server_addr` (RFC 8656 §7: a
/// Refresh with LIFETIME 0), whose Allocate answer this side never got: an
/// unauthenticated Refresh for the server's nonce and realm, then the signed
/// one. A 437 to the signed Refresh means nothing was held: also done.
async fn release_allocation(
    conn: &(dyn Conn + Send + Sync),
    server_addr: &str,
    server: &TurnServer,
) -> Result<(), String> {
    use webrtc::stun::attributes::{ATTR_NONCE, ATTR_REALM, ATTR_USERNAME};
    use webrtc::stun::error_code::{CODE_ALLOC_MISMATCH, ErrorCodeAttribute};
    use webrtc::stun::fingerprint::FINGERPRINT;
    use webrtc::stun::integrity::MessageIntegrity;
    use webrtc::stun::message::{
        CLASS_ERROR_RESPONSE, CLASS_REQUEST, Getter, METHOD_REFRESH, Message, MessageType, Setter,
    };
    use webrtc::stun::textattrs::TextAttribute;
    use webrtc::turn::proto::lifetime::Lifetime;

    let to: SocketAddr = tokio::net::lookup_host(server_addr)
        .await
        .map_err(|e| e.to_string())?
        .next()
        .ok_or("no TURN server address")?;
    let refresh = |extra: Vec<Box<dyn Setter>>| -> Result<Message, String> {
        let mut setters: Vec<Box<dyn Setter>> = vec![
            Box::new(webrtc::stun::agent::TransactionId::new()),
            Box::new(MessageType::new(METHOD_REFRESH, CLASS_REQUEST)),
            Box::new(Lifetime(Duration::ZERO)),
        ];
        setters.extend(extra);
        setters.push(Box::new(FINGERPRINT));
        let mut msg = Message::new();
        msg.build(&setters).map_err(|e| e.to_string())?;
        Ok(msg)
    };
    let unsigned = refresh(Vec::new())?;
    let challenge = transact(conn, to, &unsigned).await?;
    let realm = TextAttribute::get_from_as(&challenge, ATTR_REALM).map_err(|e| e.to_string())?;
    let nonce = TextAttribute::get_from_as(&challenge, ATTR_NONCE).map_err(|e| e.to_string())?;
    let integrity = MessageIntegrity::new_long_term_integrity(
        server.username.clone(),
        realm.text.clone(),
        server.credential.clone(),
    );
    let signed = refresh(vec![
        Box::new(TextAttribute::new(ATTR_USERNAME, server.username.clone())),
        Box::new(realm),
        Box::new(nonce),
        Box::new(integrity),
    ])?;
    let answer = transact(conn, to, &signed).await?;
    if answer.typ.class == CLASS_ERROR_RESPONSE {
        let mut code = ErrorCodeAttribute::default();
        if code.get_from(&answer).is_ok() && code.code == CODE_ALLOC_MISMATCH {
            return Ok(());
        }
        return Err(format!("Refresh error response ({})", code.code.0));
    }
    Ok(())
}

/// Send `request` to `to` on `conn` and return the response with its
/// transaction id, retransmitting after [`RELEASE_RTO`], doubled each time.
async fn transact(
    conn: &(dyn Conn + Send + Sync),
    to: SocketAddr,
    request: &webrtc::stun::message::Message,
) -> Result<webrtc::stun::message::Message, String> {
    let mut buffer = vec![0u8; 1500];
    let mut wait = RELEASE_RTO;
    for _ in 0..RELEASE_SENDS {
        conn.send_to(&request.raw, to).await.map_err(|e| e.to_string())?;
        let deadline = tokio::time::Instant::now() + wait;
        loop {
            let Ok(received) = tokio::time::timeout_at(deadline, conn.recv_from(&mut buffer)).await else {
                break;
            };
            let (len, _) = received.map_err(|e| e.to_string())?;
            let mut answer = webrtc::stun::message::Message::new();
            answer.raw = buffer[..len].to_vec();
            if answer.decode().is_ok() && answer.transaction_id == request.transaction_id {
                return Ok(answer);
            }
        }
        wait *= 2;
    }
    Err("TURN server did not answer".to_owned())
}

/// Returns once the STUN wait beside an allocation saw UDP look blocked;
/// never when there is no STUN wait, or it ended with UDP answering.
async fn until_silent(silent: Option<watch::Receiver<bool>>) {
    if let Some(mut silent) = silent {
        if silent.wait_for(|silent| *silent).await.is_ok() {
            return;
        }
    }
    std::future::pending::<()>().await;
}

/// `attempt`, or `None` when it fails or takes longer than `limit`.
async fn bounded(
    limit: Duration,
    attempt: impl std::future::Future<Output = Result<TurnCarrier, String>>,
) -> Option<TurnCarrier> {
    match tokio::time::timeout(limit, attempt).await {
        Ok(Ok(carrier)) => Some(carrier),
        Ok(Err(error)) => {
            tracing::debug!(%error, "TURN allocation failed");
            None
        }
        Err(_) => {
            tracing::debug!("TURN allocation timed out");
            None
        }
    }
}

impl Drop for TurnCarrier {
    fn drop(&mut self) {
        // The sender (the first task) stops on its own once the queue is
        // closed: aborting it in the middle of a write would leave half a
        // message on a stream.
        self.queue.close();
        for task in self.tasks.iter().skip(1) {
            task.abort();
        }
        // Release the allocation; without a runtime it simply expires.
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            let (relay, client) = (Arc::clone(&self.relay), self.client.clone());
            runtime.spawn(async move {
                let _ = relay.close().await;
                let _ = client.close().await;
            });
        }
    }
}

/// One timed TURN allocation (measurement support: cmux-mobile-path-probe).
#[derive(Debug, Clone)]
pub struct TimedAllocation {
    /// The server allocated on (`host:port`).
    pub server: String,
    pub transport: TurnTransport,
    /// Connect plus allocate: from the first byte sent (the TCP SYN on a
    /// stream) until the server granted the allocation.
    pub elapsed: Duration,
    /// The relayed address the server granted.
    pub relayed: SocketAddr,
}

/// Allocate once on the first TURN server of `servers` reached over
/// `transport` (TLS: on 443 first, as [`turn_servers`] ranks them), time it,
/// and release it at once. This is the allocation a WireGuard dial makes,
/// alone: no STUN beside it, no stagger.
#[doc(hidden)]
pub async fn timed_allocation(
    servers: &[IceServer],
    transport: TurnTransport,
    options: &DialOptions,
) -> Result<TimedAllocation, String> {
    let mut candidates: Vec<TurnServer> =
        servers_in_order(servers).into_iter().filter(|server| server.transport == transport).collect();
    // UDP: the first listed, as a dial takes it. A stream: 443 first (stable).
    if transport.is_stream() {
        candidates.sort_by_key(|server| !server.address.ends_with(":443"));
    }
    let server = candidates.into_iter().next().ok_or_else(|| format!("no TURN server over {transport:?}"))?;
    let address = server.address.clone();
    let started = tokio::time::Instant::now();
    let carrier = tokio::time::timeout(CONNECT_WAIT + STREAM_WAIT, TurnCarrier::allocate_on(server, options))
        .await
        .map_err(|_| "TURN allocation timed out".to_owned())??;
    let elapsed = started.elapsed();
    let relayed = carrier.relayed;
    drop(carrier);
    Ok(TimedAllocation { server: address, transport, elapsed, relayed })
}

/// Every TURN server of `servers`, in the order listed.
fn servers_in_order(servers: &[IceServer]) -> Vec<TurnServer> {
    servers
        .iter()
        .filter_map(|server| Some((server, server.username.as_deref()?, server.credential.as_deref()?)))
        .flat_map(|(server, username, credential)| {
            server.urls.iter().filter_map(move |url| parse_url(url, username, credential))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// lossy-3 lost 2 dials in 20 (lan_roundtrip, before): the server's
    /// answer to the Allocate was lost, the client's retransmit met the
    /// allocation that answer made, the server said 437, and the dial had
    /// no relay. A fresh socket's allocation must come up instead.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_lost_allocate_answer_still_allocates() {
        let turn = crate::testing::TestTurn::start().await;
        turn.drop_allocate_successes(1);
        let options = DialOptions {
            ice_servers: vec![turn.udp_only()],
            include_loopback: true,
            ..DialOptions::default()
        };
        let started = tokio::time::Instant::now();
        let carrier =
            TurnCarrier::allocate(&options).await.expect("a TURN allocation despite the lost answer");
        assert_eq!(carrier.transport, TurnTransport::Udp);
        assert!(started.elapsed() < UDP_WAIT, "took {:?}", started.elapsed());
    }

    /// With UDP blocked and no stream server listed, the allocation gives
    /// up at NO_STREAM_UDP_WAIT, not after the turn crate's 7 sends (7.8 s).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_blocked_udp_allocation_with_no_stream_server_gives_up_at_its_bound() {
        let turn = crate::testing::TestTurn::start().await;
        turn.set_udp_blocked(true);
        let options = DialOptions {
            ice_servers: vec![turn.udp_only()],
            include_loopback: true,
            ..DialOptions::default()
        };
        let started = tokio::time::Instant::now();
        assert!(TurnCarrier::allocate(&options).await.is_none());
        let elapsed = started.elapsed();
        assert!(elapsed >= NO_STREAM_UDP_WAIT - Duration::from_millis(50), "took {elapsed:?}");
        assert!(elapsed < NO_STREAM_UDP_WAIT + Duration::from_millis(500), "took {elapsed:?}");
    }

    fn ice(urls: &[&str]) -> Vec<IceServer> {
        vec![IceServer {
            urls: urls.iter().map(|url| (*url).to_owned()).collect(),
            username: Some("u".into()),
            credential: Some("c".into()),
        }]
    }

    /// Cloudflare's `generate-ice-servers` list: UDP 3478 first, then TLS
    /// on 443 over TLS on 5349 and plain TCP.
    #[test]
    fn picks_udp_then_tls_on_443() {
        let servers = ice(&[
            "stun:stun.cloudflare.com:3478",
            "turn:turn.cloudflare.com:3478?transport=udp",
            "turn:turn.cloudflare.com:3478?transport=tcp",
            "turn:turn.cloudflare.com:80?transport=tcp",
            "turns:turn.cloudflare.com:5349?transport=tcp",
            "turns:turn.cloudflare.com:443?transport=tcp",
        ]);
        let (udp, stream) = turn_servers(&servers);
        let udp = udp.unwrap();
        assert_eq!((udp.address.as_str(), udp.transport), ("turn.cloudflare.com:3478", TurnTransport::Udp));
        let stream = stream.unwrap();
        assert_eq!(
            (stream.address.as_str(), stream.transport),
            ("turn.cloudflare.com:443", TurnTransport::Tls)
        );
        assert_eq!(stream.host, "turn.cloudflare.com");
        assert_eq!((stream.username.as_str(), stream.credential.as_str()), ("u", "c"));
        // Only plain TCP: that is the stream.
        let (_, tcp) = turn_servers(&ice(&["turn:t.example:80?transport=tcp"]));
        assert_eq!(tcp.unwrap().transport, TurnTransport::Tcp);
        // Defaults and IPv6.
        let (udp, stream) = turn_servers(&ice(&["turn:[2001:db8::1]", "turns:t.example"]));
        assert_eq!(udp.unwrap().address, "[2001:db8::1]:3478");
        assert_eq!(stream.unwrap().address, "t.example:5349");
        // No credentials, no TURN.
        let bare = vec![IceServer { urls: vec!["turn:t.example".into()], username: None, credential: None }];
        assert_eq!(turn_servers(&bare), (None, None));
    }

    #[test]
    fn udp_blocked_and_relay_only_need_their_server() {
        let udp_only = DialOptions { ice_servers: ice(&["turn:t.example:3478"]), ..DialOptions::default() };
        assert!(missing_turn(&udp_only).is_none());
        assert!(missing_turn(&DialOptions { block_udp: true, ..udp_only.clone() }).is_some());
        assert!(missing_turn(&DialOptions { relay_only: true, ..udp_only }).is_none());
        let stun_only = DialOptions { ice_servers: ice(&["stun:s.example:3478"]), ..DialOptions::default() };
        assert!(missing_turn(&DialOptions { relay_only: true, ..stun_only }).is_some());
        let tls = DialOptions {
            ice_servers: ice(&["turns:t.example:443?transport=tcp"]),
            block_udp: true,
            ..DialOptions::default()
        };
        assert!(missing_turn(&tls).is_none());
    }

    /// STUN and padded ChannelData messages come out of a byte stream one
    /// by one, however the bytes were split.
    #[tokio::test]
    async fn stream_framing_splits_stun_and_padded_channel_data() {
        let mut stun = vec![0x01, 0x01, 0x00, 0x08];
        stun.extend_from_slice(&[0x21, 0x12, 0xA4, 0x42]);
        stun.extend_from_slice(&[7; 12]);
        stun.extend_from_slice(&[9; 8]);
        // ChannelData 0x4000 with 5 bytes, padded with 3 zeros.
        let mut channel = vec![0x40, 0x00, 0x00, 0x05, 1, 2, 3, 4, 5, 0, 0, 0];
        let mut wire = stun.clone();
        wire.append(&mut channel);
        let (mut client, mut server) = tokio::io::duplex(8);
        let writer = tokio::spawn(async move {
            for chunk in wire.chunks(3) {
                server.write_all(chunk).await.unwrap();
            }
        });
        let mut buffer = vec![0u8; MAX_MESSAGE];
        let len = read_message(&mut client, &mut buffer).await.unwrap().unwrap();
        assert_eq!(&buffer[..len], &stun[..]);
        let len = read_message(&mut client, &mut buffer).await.unwrap().unwrap();
        assert_eq!(&buffer[..len], &[0x40, 0x00, 0x00, 0x05, 1, 2, 3, 4, 5]);
        writer.await.unwrap();
        assert_eq!(read_message(&mut client, &mut buffer).await.unwrap(), None);
        // Neither STUN nor ChannelData: the stream is unusable.
        let (mut client, mut server) = tokio::io::duplex(64);
        server.write_all(&[0xC0, 0, 0, 0]).await.unwrap();
        assert!(read_message(&mut client, &mut buffer).await.is_err());
    }
}
