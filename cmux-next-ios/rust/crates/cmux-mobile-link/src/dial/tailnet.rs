//! Tailscale-only links (PROTOCOL.md "Tailscale-only links"): the link rides
//! one plain TCP connection between the phone's and the Mac's tailnet
//! addresses, through the Tailscale app's own tunnel. Nothing of the
//! built-in transport runs: no WireGuard keys, no STUN, no TURN, no ICE.
//!
//! The hub still introduces the two sides, so the phone's device id and user
//! stay the ones the backend stamped (hostd admits the dial by `fromUserId`
//! before this code runs, and pairing's `auth` runs on the link as on any
//! other):
//!
//! 1. phone → Mac, `tailnet-init {token, lanes}`: 32 random bytes (hex) that
//!    only the Mac hears, through the hub.
//! 2. The Mac opens a one-session TCP listener on each of its tailnet
//!    addresses (100.64.0.0/10, fd7a:115c:a1e0::/48) and answers
//!    `tailnet-resp {endpoints, lanes}`; with no tailnet address it ends the
//!    session `bye {reason:"tailscale_off_mac"}`.
//! 3. The phone connects to an endpoint and writes the hello
//!    `CMXTN1 | u8 lane | token`; the Mac answers one byte `1` and the
//!    connection is the link's main stream (lane 0) or its input lane
//!    (lane 1). A connection with another token, from an address off the
//!    tailnet, or that says nothing for 5 s is closed; the listener keeps
//!    waiting until the dial's bound.
//!
//! The phone refuses to dial (`tailscale_off_phone`) when it has no tailnet
//! address itself: Tailscale is not running or not connected on it.

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot, watch};

use super::{
    DialError, DialFuture, Dialed, Dialer, LinkPath, LinkStream, SessionEvents, TransportKind,
    input_lane_agreed, is_cgnat, offered_lanes,
};
use crate::signaling::{SessionEvent, SignalEnvelope, SignalPayload, SignalingClient};

/// The hello's first bytes.
const MAGIC: &[u8; 6] = b"CMXTN1";
/// The token's length in bytes (64 hex characters on the wire).
const TOKEN_LEN: usize = 32;
/// A connection must send its hello within this.
const HELLO_TIMEOUT: Duration = Duration::from_secs(5);
/// One TCP connect attempt's bound (an address the tailnet cannot route
/// right now: the Mac's Tailscale is off or it sleeps).
const CONNECT_TIMEOUT: Duration = Duration::from_secs(6);
/// A later endpoint starts this long after the one before it.
const CONNECT_STAGGER: Duration = Duration::from_millis(150);
/// How long the Mac keeps listening for the main stream (the dial's own bound is 25 s).
const MAIN_WAIT: Duration = Duration::from_secs(30);
/// How long the Mac keeps listening for the input lane after the main stream.
const LANE_WAIT: Duration = Duration::from_secs(10);
/// At most this many bad connections per session before the Mac stops listening.
const MAX_BAD_HELLOS: usize = 16;
/// At most this many endpoints are offered or tried.
const MAX_ENDPOINTS: usize = 8;

/// The bye reason a Mac with no tailnet address answers.
pub const TAILSCALE_OFF_MAC: &str = "tailscale_off_mac";
/// The dial error's prefix when this phone has no tailnet address.
pub const TAILSCALE_OFF_PHONE: &str = "tailscale_off_phone";

pub struct TailnetDialer;

/// Why a Tailscale-only dial failed, for the app's message and its fallback.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TailnetFailure {
    /// This phone has no tailnet address: the Tailscale app is off or not connected.
    PhoneOff,
    /// The Mac has no tailnet address: Tailscale is off on the Mac.
    MacOff,
    /// The Mac listed tailnet addresses, but none answered over the tailnet.
    Unreachable,
    /// The Mac never answered: its cmux predates Tailscale-only links (or it slept).
    NoAnswer,
    /// The cmux service does not relay Tailscale-only dials yet (`unknown payload kind`).
    ServiceTooOld,
}

impl TailnetFailure {
    /// The failure a dial error's text names, if it is one of a Tailscale-only dial's own.
    pub fn classify(message: &str) -> Option<Self> {
        if message.contains(TAILSCALE_OFF_PHONE) {
            Some(Self::PhoneOff)
        } else if message.contains(TAILSCALE_OFF_MAC) {
            Some(Self::MacOff)
        } else if message.contains("tailscale_unreachable") {
            Some(Self::Unreachable)
        } else if message.contains("tailscale_no_answer") {
            Some(Self::NoAnswer)
        } else if message.contains("unknown payload kind") {
            Some(Self::ServiceTooOld)
        } else {
            None
        }
    }
}

/// This machine's tailnet addresses (Tailscale's interface), IPv4 first.
pub fn tailnet_ips() -> Vec<IpAddr> {
    let interfaces: Vec<IpAddr> = webrtc::util::ifaces::ifaces()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|interface| interface.addr.map(|addr| addr.ip()))
        .collect();
    pick_tailnet(&interfaces)
}

/// The tailnet addresses among `interfaces`, IPv4 first, no repeats.
fn pick_tailnet(interfaces: &[IpAddr]) -> Vec<IpAddr> {
    let mut ips: Vec<IpAddr> = Vec::new();
    for want_v4 in [true, false] {
        for ip in interfaces {
            if ip.is_ipv4() == want_v4 && is_cgnat(*ip) && !ips.contains(ip) && ips.len() < MAX_ENDPOINTS {
                ips.push(*ip);
            }
        }
    }
    ips
}

/// Whether this phone can dial a Tailscale-only link now: it has a tailnet
/// address (the Tailscale app's VPN is connected).
pub fn tailscale_up() -> bool {
    !tailnet_ips().is_empty()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| text.get(i..i + 2).and_then(|pair| u8::from_str_radix(pair, 16).ok()))
        .collect()
}

/// Constant-time equality of two tokens.
fn same_token(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn hello(lane: u8, token: &[u8]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(MAGIC.len() + 1 + token.len());
    bytes.extend_from_slice(MAGIC);
    bytes.push(lane);
    bytes.extend_from_slice(token);
    bytes
}

/// Whether the Mac serves a connection from `ip`: a tailnet address, or
/// loopback when the options allow it (tests and same-host runs).
fn peer_allowed(ip: IpAddr, include_loopback: bool) -> bool {
    let ip = match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(IpAddr::V6(v6), IpAddr::V4),
        v4 => v4,
    };
    is_cgnat(ip) || (include_loopback && ip.is_loopback())
}

/// Phone side: connect to `addr`, say the hello, wait for the Mac's `1`.
async fn connect_one(addr: SocketAddr, lane: u8, token: &[u8]) -> std::io::Result<TcpStream> {
    let mut stream = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr))
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "connect timed out"))??;
    stream.set_nodelay(true)?;
    stream.write_all(&hello(lane, token)).await?;
    let mut ack = [0u8; 1];
    tokio::time::timeout(HELLO_TIMEOUT, stream.read_exact(&mut ack))
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "no answer to the hello"))??;
    if ack[0] != 1 {
        return Err(std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "hello refused"));
    }
    Ok(stream)
}

/// Phone side: the first endpoint that answers, tried in order, each a
/// little after the one before.
async fn connect_first(endpoints: &[SocketAddr], token: &[u8]) -> Result<(TcpStream, SocketAddr), DialError> {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let mut tasks = Vec::new();
    for (index, addr) in endpoints.iter().copied().enumerate() {
        let tx = tx.clone();
        let token = token.to_vec();
        tasks.push(tokio::spawn(async move {
            tokio::time::sleep(CONNECT_STAGGER * index as u32).await;
            let _ = tx.send((addr, connect_one(addr, 0, &token).await));
        }));
    }
    drop(tx);
    let mut last = String::from("the Mac listed no tailnet address");
    let mut won = None;
    while let Some((addr, result)) = rx.recv().await {
        match result {
            Ok(stream) => {
                won = Some((stream, addr));
                break;
            }
            Err(error) => last = format!("{addr}: {error}"),
        }
    }
    for task in tasks {
        task.abort();
    }
    won.ok_or_else(|| {
        DialError::Transport(format!(
            "tailscale_unreachable: the Mac's tailnet address did not answer ({last})"
        ))
    })
}

/// Mac side: the listeners on `ips`, port chosen by the OS.
async fn listen(ips: &[IpAddr]) -> Vec<TcpListener> {
    let mut listeners = Vec::new();
    for ip in ips {
        match TcpListener::bind(SocketAddr::new(*ip, 0)).await {
            Ok(listener) => listeners.push(listener),
            Err(error) => tracing::warn!(%ip, %error, "tailnet listener not bound"),
        }
    }
    listeners
}

/// Mac side: accept connections on every listener until `main` and (when
/// agreed) the lane are taken, a bound passes, or too many bad hellos.
async fn serve(
    listeners: Vec<TcpListener>,
    token: Vec<u8>,
    include_loopback: bool,
    main: oneshot::Sender<(TcpStream, SocketAddr)>,
    lane: Option<oneshot::Sender<Box<dyn LinkStream>>>,
) {
    let (tx, mut rx) = mpsc::unbounded_channel::<(TcpStream, SocketAddr)>();
    let accepts: Vec<_> = listeners
        .into_iter()
        .map(|listener| {
            let tx = tx.clone();
            tokio::spawn(async move {
                while let Ok((stream, from)) = listener.accept().await {
                    if tx.send((stream, from)).is_err() {
                        return;
                    }
                }
            })
        })
        .collect();
    drop(tx);
    let (hello_tx, mut hello_rx) = mpsc::unbounded_channel::<Option<(u8, TcpStream, SocketAddr)>>();
    let mut main = Some(main);
    let mut lane = lane;
    let mut bad = 0usize;
    // Until the main stream comes, then for the lane: never longer.
    let mut deadline = tokio::time::Instant::now() + MAIN_WAIT;
    loop {
        if main.is_none() && lane.is_none() {
            break;
        }
        if main.as_ref().is_some_and(oneshot::Sender::is_closed) {
            // The answer gave up (its bound passed): nobody takes the stream.
            break;
        }
        tokio::select! {
            accepted = rx.recv() => {
                let Some((mut stream, from)) = accepted else { break };
                if !peer_allowed(from.ip(), include_loopback) {
                    tracing::warn!(%from, "tailnet: refusing a connection from off the tailnet");
                    bad += 1;
                } else {
                    let token = token.clone();
                    let hello_tx = hello_tx.clone();
                    tokio::spawn(async move {
                        let mut buffer = [0u8; MAGIC.len() + 1 + TOKEN_LEN];
                        let read = tokio::time::timeout(HELLO_TIMEOUT, stream.read_exact(&mut buffer)).await;
                        let good = matches!(read, Ok(Ok(_)))
                            && &buffer[..MAGIC.len()] == MAGIC
                            && same_token(&buffer[MAGIC.len() + 1..], &token);
                        let _ = hello_tx.send(good.then(|| (buffer[MAGIC.len()], stream, from)));
                    });
                }
            }
            checked = hello_rx.recv() => match checked.flatten() {
                Some((0, mut stream, from)) if main.is_some() => {
                    if stream.write_all(&[1]).await.is_ok() && stream.set_nodelay(true).is_ok()
                        && let Some(main) = main.take() {
                        let _ = main.send((stream, from));
                        deadline = tokio::time::Instant::now() + LANE_WAIT;
                    }
                }
                Some((1, mut stream, _)) if lane.is_some() => {
                    if stream.write_all(&[1]).await.is_ok() && stream.set_nodelay(true).is_ok()
                        && let Some(lane) = lane.take() {
                        let _ = lane.send(Box::new(stream));
                    }
                }
                _ => {
                    bad += 1;
                    tracing::warn!(bad, "tailnet: a connection with a wrong hello");
                }
            },
            () = tokio::time::sleep_until(deadline) => break,
        }
        if bad >= MAX_BAD_HELLOS {
            tracing::warn!("tailnet: too many bad connections; listener closed");
            break;
        }
    }
    for accept in accepts {
        accept.abort();
    }
}

fn dialed(
    stream: TcpStream,
    peer: SocketAddr,
    lane: Option<oneshot::Receiver<Box<dyn LinkStream>>>,
) -> Dialed {
    let (path_tx, path) = watch::channel(LinkPath::Direct);
    let (peer_tx, peer_rx) = watch::channel(Some(peer.ip()));
    Dialed {
        stream: Box::new(stream),
        path,
        peer: peer_rx,
        // The watch senders live as long as the link: a dropped sender would
        // read as "changed" to whoever follows the path.
        guard: Box::new((path_tx, peer_tx)),
        lane,
        media: None,
        webrtc_media: false,
        hold: None,
        liveness: None,
        // The tailnet's keys belong to Tailscale, not to this link.
        tunnel_keys: None,
    }
}

impl Dialer for TailnetDialer {
    fn kind(&self) -> TransportKind {
        TransportKind::Tailnet
    }

    fn dial<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        mac: &'a str,
        session_id: &'a str,
        mut events: SessionEvents,
        options: &'a super::DialOptions,
    ) -> DialFuture<'a> {
        Box::pin(async move {
            if !options.include_loopback && !tailscale_up() {
                return Err(DialError::Transport(format!(
                    "{TAILSCALE_OFF_PHONE}: Tailscale is not connected on this iPhone"
                )));
            }
            let mut token = [0u8; TOKEN_LEN];
            getrandom::fill(&mut token).map_err(|error| DialError::Transport(error.to_string()))?;
            options.timeline.mark("offer_sent");
            signaling
                .send_signal(
                    mac,
                    session_id,
                    SignalPayload::TailnetInit {
                        token: hex(&token),
                        lanes: offered_lanes(options, false, false),
                    },
                )
                .map_err(|error| DialError::Signaling(error.to_string()))?;
            let (endpoints, peer_lanes) = tokio::time::timeout(options.answer_timeout, async {
                loop {
                    match events.next().await? {
                        SessionEvent::Signal(SignalEnvelope {
                            payload: SignalPayload::TailnetResp { endpoints, lanes }, ..
                        }) => return Ok((endpoints, lanes)),
                        SessionEvent::Signal(SignalEnvelope { payload: SignalPayload::Bye { reason }, .. }) => {
                            return Err(DialError::Bye(reason));
                        }
                        _ => {}
                    }
                }
            })
            .await
            .map_err(|_| {
                DialError::Transport(
                    "tailscale_no_answer: the Mac did not answer a Tailscale-only dial (its cmux may predate it)".into(),
                )
            })??;
            options.timeline.mark("answer_received");
            let endpoints: Vec<SocketAddr> = endpoints
                .iter()
                .filter_map(|text| text.parse::<SocketAddr>().ok())
                .filter(|addr| peer_allowed(addr.ip(), options.include_loopback))
                .take(MAX_ENDPOINTS)
                .collect();
            if endpoints.is_empty() {
                return Err(DialError::Bye(TAILSCALE_OFF_MAC.into()));
            }
            let (stream, addr) = connect_first(&endpoints, &token).await?;
            options.timeline.mark("channel_open");
            let lane = input_lane_agreed(options, &peer_lanes).then(|| {
                let (tx, rx) = oneshot::channel::<Box<dyn LinkStream>>();
                tokio::spawn(async move {
                    match connect_one(addr, 1, &token).await {
                        Ok(stream) => {
                            let _ = tx.send(Box::new(stream));
                        }
                        Err(error) => tracing::debug!(%error, "tailnet input lane did not open"),
                    }
                });
                rx
            });
            Ok(dialed(stream, addr, lane))
        })
    }

    fn answer<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        first: SignalEnvelope,
        _events: SessionEvents,
        options: &'a super::DialOptions,
    ) -> DialFuture<'a> {
        Box::pin(async move {
            let SignalPayload::TailnetInit { token, lanes } = &first.payload else {
                return Err(DialError::Unexpected("not a tailnet-init".into()));
            };
            let token = unhex(token)
                .filter(|token| token.len() == TOKEN_LEN)
                .ok_or_else(|| DialError::Unexpected("tailnet-init token is not 32 bytes of hex".into()))?;
            let mut ips = tailnet_ips();
            if options.include_loopback {
                ips.push(IpAddr::V4(std::net::Ipv4Addr::LOCALHOST));
            }
            let listeners = listen(&ips).await;
            if listeners.is_empty() {
                return Err(DialError::Transport(TAILSCALE_OFF_MAC.into()));
            }
            let endpoints: Vec<String> = listeners
                .iter()
                .filter_map(|listener| listener.local_addr().ok())
                .map(|addr| addr.to_string())
                .collect();
            let lane_agreed = input_lane_agreed(options, lanes);
            signaling
                .send_signal(
                    &first.from,
                    &first.session_id,
                    SignalPayload::TailnetResp { endpoints, lanes: offered_lanes(options, false, false) },
                )
                .map_err(|error| DialError::Signaling(error.to_string()))?;
            let (main_tx, main_rx) = oneshot::channel();
            let (lane_tx, lane_rx) = if lane_agreed {
                let (tx, rx) = oneshot::channel();
                (Some(tx), Some(rx))
            } else {
                (None, None)
            };
            tokio::spawn(serve(listeners, token, options.include_loopback, main_tx, lane_tx));
            let (stream, peer) = main_rx
                .await
                .map_err(|_| DialError::Transport("no phone connected over the tailnet".into()))?;
            Ok(dialed(stream, peer, lane_rx))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn only_tailnet_addresses_are_picked_ipv4_first() {
        let interfaces = [
            ip("192.168.1.4"),
            ip("fd7a:115c:a1e0::12"),
            ip("100.101.102.103"),
            ip("10.0.0.2"),
            ip("100.101.102.103"),
            ip("fe80::1"),
        ];
        assert_eq!(pick_tailnet(&interfaces), vec![ip("100.101.102.103"), ip("fd7a:115c:a1e0::12")]);
        assert!(pick_tailnet(&[ip("192.168.1.4"), ip("127.0.0.1")]).is_empty());
    }

    #[test]
    fn the_mac_serves_only_the_tailnet_and_loopback_when_allowed() {
        assert!(peer_allowed(ip("100.64.0.1"), false));
        assert!(peer_allowed(ip("::ffff:100.70.1.2"), false));
        assert!(peer_allowed(ip("fd7a:115c:a1e0::5"), false));
        assert!(!peer_allowed(ip("192.168.1.4"), false));
        assert!(!peer_allowed(ip("127.0.0.1"), false));
        assert!(peer_allowed(ip("127.0.0.1"), true));
        assert!(!peer_allowed(ip("8.8.8.8"), true));
    }

    #[test]
    fn failures_are_classified_from_the_dial_errors_text() {
        let phone =
            DialError::Transport(format!("{TAILSCALE_OFF_PHONE}: Tailscale is not connected on this iPhone"));
        assert_eq!(TailnetFailure::classify(&phone.to_string()), Some(TailnetFailure::PhoneOff));
        let mac = DialError::Bye(TAILSCALE_OFF_MAC.into());
        assert_eq!(TailnetFailure::classify(&mac.to_string()), Some(TailnetFailure::MacOff));
        // The Mac's own answer error comes back as its bye reason.
        let mac_bye = DialError::Bye(DialError::Transport(TAILSCALE_OFF_MAC.into()).to_string());
        assert_eq!(TailnetFailure::classify(&mac_bye.to_string()), Some(TailnetFailure::MacOff));
        assert_eq!(
            TailnetFailure::classify("refused: bad_request: unknown payload kind"),
            Some(TailnetFailure::ServiceTooOld)
        );
        assert_eq!(TailnetFailure::classify("timed out"), None);
    }

    #[test]
    fn tokens_round_trip_and_compare() {
        let token = [7u8; TOKEN_LEN];
        assert_eq!(unhex(&hex(&token)).unwrap(), token.to_vec());
        assert!(unhex("abc").is_none());
        assert!(unhex("zz").is_none());
        assert!(same_token(&token, &token));
        assert!(!same_token(&token, &[8u8; TOKEN_LEN]));
        assert!(!same_token(&token, &token[..31]));
    }

    #[tokio::test]
    async fn a_wrong_token_is_refused_and_the_right_one_is_served() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let token = vec![3u8; TOKEN_LEN];
        let (main_tx, main_rx) = oneshot::channel();
        tokio::spawn(serve(vec![listener], token.clone(), true, main_tx, None));
        let wrong = connect_one(addr, 0, &[4u8; TOKEN_LEN]).await;
        assert!(wrong.is_err(), "a wrong token must not get the ack");
        let mut phone = connect_one(addr, 0, &token).await.expect("the right token is served");
        let (mut mac, _) = main_rx.await.unwrap();
        phone.write_all(b"ping").await.unwrap();
        let mut got = [0u8; 4];
        mac.read_exact(&mut got).await.unwrap();
        assert_eq!(&got, b"ping");
    }

    #[tokio::test]
    async fn the_input_lane_is_a_second_connection() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let token = vec![9u8; TOKEN_LEN];
        let (main_tx, main_rx) = oneshot::channel();
        let (lane_tx, lane_rx) = oneshot::channel();
        tokio::spawn(serve(vec![listener], token.clone(), true, main_tx, Some(lane_tx)));
        let _main = connect_one(addr, 0, &token).await.unwrap();
        let _ = main_rx.await.unwrap();
        let mut lane = connect_one(addr, 1, &token).await.unwrap();
        let mut mac_lane = lane_rx.await.unwrap();
        lane.write_all(b"k").await.unwrap();
        let mut got = [0u8; 1];
        mac_lane.read_exact(&mut got).await.unwrap();
        assert_eq!(&got, b"k");
    }
}
