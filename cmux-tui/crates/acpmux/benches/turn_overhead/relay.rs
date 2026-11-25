//! The bench's relay route (`--route relay`): the chat's clients reach the daemon through a real
//! relay, as a chat on a Cloud machine does, instead of the local socket.
//!
//! A Cloud chat crosses the Cloud carrier: the platform's relay (the Worker in
//! `relays/cloudflare-do`; `cmux-relay` is its native port, the same wire), cmux-remote's relay
//! client on both ends, and a Noise XX link inside the circuit, which the machine's side bridges
//! to acpmux (`docs/carrier-roles.md`, `src/hub_carrier.rs`). Here, all on loopback with no
//! network and no account:
//!
//! - the relay is `cmux-relay` in this process, open (tickets are the platform's tests);
//! - the machine's side is acpmux's own [`HubCarrier`], registered on the relay, which bridges
//!   each admitted circuit to [`Bridge`], a loopback listener that carries the bytes on to the
//!   daemon's unix socket (the machine's own hop from the carrier to acpmux);
//! - the client's side is the same dial as [`HubCarrier::dial`] (cmux-remote's relay client,
//!   then `initiate_secure_link` with the machine's key pinned), done here in its two steps so
//!   the attach is timed by step: `connect` (ticket, relay allocation and join, until the
//!   circuit opened) and `handshake` (the Noise exchange).
//!
//! Each side reaches the relay through its own [`Tap`], a loopback TCP hop that stamps every
//! read on the wall clock. A turn's `relay_in` is the prompt's first bytes into the relay until
//! its first bytes out to the machine's side; `relay_out` is the reply's first bytes from the
//! machine's side into the relay until its first bytes out to the client. Each tap adds one
//! loopback copy to the route, which the platform's network replaces.

use acpmux::hub_carrier::{CarrierAnswer, HubCarrier, HubServe, Tickets, Timings};
use base64::Engine;
use bytes::Bytes;
use cmux_remote::crypto::{
    ClientAuthMode, ClientHandshake, ConnectionAttemptId, StaticIdentity, initiate_secure_link,
};
use cmux_remote::link::FrameLink;
use cmux_remote::provider::{
    ConnectRequest, LinkRequest, RelayClientConfig, RelayCredentialSource, RelayProvider,
    TransportProvider,
};
use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
use serde_json::json;
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UnixStream};

use super::{BoxStream, wall_ns};

/// The machine's slot on the relay.
const SLOT: &str = "turn-bench-machine";
/// The largest relay frame, the Noise record limit (`hub_carrier.rs` `MAX_FRAME_BYTES`).
const MAX_FRAME_BYTES: usize = 65_535;
/// Bytes read from the client before they go out as one record (`hub_carrier.rs` `CHUNK_BYTES`).
const CHUNK_BYTES: usize = 16 * 1024;
/// The duplex buffer between the client and its Noise link (`hub_carrier.rs` `DUPLEX_BYTES`).
const DUPLEX_BYTES: usize = 64 * 1024;
/// One relay control step, and the Noise exchange, may take this long.
const STEP_LIMIT: Duration = Duration::from_secs(10);

/// Which way bytes crossed a tap.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Way {
    /// From that side into the relay.
    In,
    /// From the relay out to that side.
    Out,
}

/// A loopback TCP hop in front of the relay that stamps every read (wall clock ns).
struct Tap {
    port: u16,
    reads: Arc<Mutex<Vec<(u64, Way)>>>,
}

impl Tap {
    async fn start(relay: SocketAddr) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let reads: Arc<Mutex<Vec<(u64, Way)>>> = Arc::default();
        let stamps = reads.clone();
        tokio::spawn(async move {
            while let Ok((inbound, _)) = listener.accept().await {
                let Ok(outbound) = TcpStream::connect(relay).await else { continue };
                let _ = inbound.set_nodelay(true);
                let _ = outbound.set_nodelay(true);
                let stamps = stamps.clone();
                tokio::spawn(async move {
                    let (ir, iw) = inbound.into_split();
                    let (or, ow) = outbound.into_split();
                    tokio::select! {
                        () = copy(ir, ow, &stamps, Way::In) => {}
                        () = copy(or, iw, &stamps, Way::Out) => {}
                    }
                });
            }
        });
        Self { port, reads }
    }

    fn route(&self) -> String {
        format!("relay+ws://127.0.0.1:{}", self.port)
    }

    fn clear(&self) {
        self.reads.lock().unwrap().clear();
    }

    /// The first read `way` at or after `since` (wall ns).
    fn first(&self, way: Way, since: u64) -> Option<u64> {
        self.reads
            .lock()
            .unwrap()
            .iter()
            .filter(|(t, w)| *w == way && *t >= since)
            .map(|r| r.0)
            .min()
    }
}

async fn copy(
    mut from: impl AsyncReadExt + Unpin,
    mut to: impl AsyncWriteExt + Unpin,
    stamps: &Mutex<Vec<(u64, Way)>>,
    way: Way,
) {
    let mut buf = vec![0u8; 64 << 10];
    loop {
        let n = match from.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        stamps.lock().unwrap().push((wall_ns(), way));
        if to.write_all(&buf[..n]).await.is_err() {
            return;
        }
    }
}

/// The platform's answers for the bench's one slot, as `POST /v1/mesh/carrier` gives them.
struct OpenTickets {
    relay: String,
    /// Register: the client's key, the one key the machine lets in.
    client: String,
}

#[async_trait::async_trait]
impl Tickets for OpenTickets {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        serde_json::from_value(json!({"relay": self.relay, "slot": SLOT,
            "ticket": "open-register", "expires_at": 0, "peers": [self.client]}))
        .map_err(|e| e.to_string())
    }

    async fn connect(&self, _peer: &str) -> Result<CarrierAnswer, String> {
        Err("the bench dials with its own client".into())
    }
}

/// The machine's hop from its carrier to acpmux: a loopback listener whose every connection is
/// carried on to the daemon's unix socket.
struct Bridge {
    address: SocketAddr,
}

impl Bridge {
    async fn start(socket: PathBuf) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((tcp, _)) = listener.accept().await {
                let _ = tcp.set_nodelay(true);
                let Ok(unix) = UnixStream::connect(&socket).await else { continue };
                tokio::spawn(async move {
                    let (mut tcp, mut unix) = (tcp, unix);
                    let _ = tokio::io::copy_bidirectional(&mut tcp, &mut unix).await;
                });
            }
        });
        Self { address }
    }
}

/// One dial's attach steps, in microseconds.
pub struct Attach {
    pub connect: f64,
    pub handshake: f64,
}

/// A turn's relay stages, in microseconds.
pub struct Crossing {
    pub relay_in: Option<f64>,
    pub relay_out: Option<f64>,
}

/// The relay, the machine's side registered on it, and the client's key and route.
pub struct RelayRoute {
    client_tap: Tap,
    machine_tap: Tap,
    client_key: [u8; 32],
    machine_key: [u8; 32],
    _serve: HubServe,
    _machine: Arc<HubCarrier>,
    _bridge: Bridge,
}

fn random_key() -> [u8; 32] {
    let mut key = [0u8; 32];
    getrandom::fill(&mut key).unwrap();
    key
}

fn random_16() -> [u8; 16] {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).unwrap();
    bytes
}

impl RelayRoute {
    /// Starts the relay on loopback, the machine's side in front of the daemon at `socket`, and
    /// returns once the machine is registered (a first dial goes through).
    pub async fn start(socket: &Path) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let relay = cmux_relay::Relay::new(cmux_relay::RelayConfig {
            allow_open: true,
            ..cmux_relay::RelayConfig::default()
        })
        .unwrap();
        let (listener, router) = relay.server_parts(listener);
        tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        });
        let client_tap = Tap::start(address).await;
        let machine_tap = Tap::start(address).await;
        let bridge = Bridge::start(socket.to_owned()).await;
        let (client_key, machine_key) = (random_key(), random_key());
        let client = base64::engine::general_purpose::STANDARD
            .encode(StaticIdentity::from_private(client_key).public_key());
        let tickets = Arc::new(OpenTickets { relay: machine_tap.route(), client });
        let timings = Timings { control: STEP_LIMIT, handshake: STEP_LIMIT, ..Timings::default() };
        let machine = HubCarrier::new(tickets, machine_key, timings);
        let serve = machine.serve(bridge.address);
        let route = Self {
            client_tap,
            machine_tap,
            client_key,
            machine_key,
            _serve: serve,
            _machine: machine,
            _bridge: bridge,
        };
        // The registration is the carrier's own task: a dial before it lands parks or fails.
        let started = Instant::now();
        loop {
            match route.try_dial().await {
                Ok((stream, _)) => {
                    drop(stream);
                    break;
                }
                Err(e) if started.elapsed() > Duration::from_secs(30) => {
                    panic!("the machine never registered on the relay: {e}")
                }
                Err(_) => tokio::time::sleep(Duration::from_millis(20)).await,
            }
        }
        route
    }

    /// A new circuit to the daemon, as `HubCarrier::dial` makes one, timed by step.
    pub async fn dial(&self) -> (BoxStream, Attach) {
        self.try_dial().await.expect("a relay dial")
    }

    async fn try_dial(&self) -> Result<(BoxStream, Attach), String> {
        let started = Instant::now();
        let provider = RelayProvider::with_credentials(
            RelayClientConfig {
                slot: SLOT.into(),
                ticket: String::new(),
                maximum_frame_bytes: MAX_FRAME_BYTES,
                control_timeout: STEP_LIMIT,
            },
            RelayCredentialSource::callback(|| async { Ok::<_, String>("open-connect".into()) }),
        )
        .map_err(|e| e.to_string())?;
        let session = SessionId(random_16());
        let endpoint = url::Url::parse(&self.client_tap.route()).map_err(|e| e.to_string())?;
        let group = provider
            .connect(ConnectRequest {
                endpoint,
                session,
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::new(),
            })
            .await
            .map_err(|e| e.to_string())?;
        let opened = group.open(LinkRequest { lane: Lane::Control, generation: 0 }).await;
        // The circuit is its own socket: the allocation socket is not needed past this.
        let _ = group.close().await;
        let link = opened.map_err(|e| e.to_string())?;
        let connected = Instant::now();
        let secure = initiate_secure_link(
            link,
            ClientHandshake {
                identity: StaticIdentity::from_private(self.client_key),
                expected_daemon: Some(StaticIdentity::from_private(self.machine_key).public_key()),
                auth: ClientAuthMode::Enrolled,
                device_name: "turn-bench".into(),
                session,
                lane: Lane::Control,
                lanes: vec![Lane::Control],
                generation: 0,
                connection_attempt: ConnectionAttemptId(random_16()),
                resume: BTreeMap::new(),
                daemon_takes_ik: false,
                handshake_timeout: STEP_LIMIT,
            },
        )
        .await
        .map_err(|e| e.to_string())?;
        let shook = Instant::now();
        let (ours, theirs) = tokio::io::duplex(DUPLEX_BYTES);
        tokio::spawn(pump(Arc::new(secure), theirs));
        let us = |d: Duration| d.as_secs_f64() * 1e6;
        let attach = Attach {
            connect: us(connected.duration_since(started)),
            handshake: us(shook.duration_since(connected)),
        };
        Ok((Box::new(ours), attach))
    }

    /// Forget every read so far: a turn's stages come from the reads after it starts.
    pub fn mark(&self) {
        self.client_tap.clear();
        self.machine_tap.clear();
    }

    /// The relay stages of a turn sent at `sent` whose reply was written at `wrote` (wall ns).
    pub fn crossing(&self, sent: u64, wrote: u64) -> Crossing {
        let us =
            |from: Option<u64>, to: Option<u64>| Some(to?.saturating_sub(from?) as f64 / 1000.0);
        Crossing {
            relay_in: us(
                self.client_tap.first(Way::In, sent),
                self.machine_tap.first(Way::Out, sent),
            ),
            relay_out: us(
                self.machine_tap.first(Way::In, wrote),
                self.client_tap.first(Way::Out, wrote),
            ),
        }
    }
}

/// Carry bytes between the client's end of a duplex and the Noise link, as the carrier's own
/// pump does (`hub_carrier.rs` `pump`).
async fn pump(link: Arc<dyn FrameLink>, io: tokio::io::DuplexStream) {
    let (mut read, mut write) = tokio::io::split(io);
    let up = async {
        let mut buf = vec![0u8; link.maximum_frame_bytes().clamp(1, CHUNK_BYTES)];
        loop {
            let n = read.read(&mut buf).await.map_err(|e| e.to_string())?;
            if n == 0 {
                return Ok::<_, String>(());
            }
            link.send(Bytes::copy_from_slice(&buf[..n])).await.map_err(|e| e.to_string())?;
        }
    };
    let down = async {
        while let Some(frame) = link.receive().await.map_err(|e| e.to_string())? {
            write.write_all(&frame).await.map_err(|e| e.to_string())?;
        }
        Ok::<_, String>(())
    };
    tokio::select! {
        _ = up => {}
        _ = down => {}
    }
    let _ = link.close().await;
}
