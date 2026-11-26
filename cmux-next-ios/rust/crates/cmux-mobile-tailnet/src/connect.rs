//! One cmux link: over the phone's tailnet node when [`route_for`] says so and the dial succeeds
//! in time, else over the relay. The node is a trait, so the same path runs with libtailscale
//! (`tsnet::TsnetNode`), on Linux in the headscale proof, and with fakes in tests.

use std::future::Future;
use std::time::{Duration, Instant};

use tokio::io::{AsyncRead, AsyncWrite};

use crate::Mode;
use crate::route::{NodeState, PeerPath, RelayReason, Route, RouteChange, RouteTracker, route_for};

/// A byte stream either route hands back.
pub trait LinkStream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> LinkStream for T {}
pub type Stream = Box<dyn LinkStream>;

/// The phone's tailnet node, as the link sees it.
pub trait PhoneNode: Send + Sync {
    fn state(&self) -> NodeState;
    /// The peer by MagicDNS name, host name or tailnet address; None when the node sees no such
    /// peer.
    fn peer(&self, host: &str) -> Option<PeerPath>;
    /// A TCP connection to `addr:port` through the node.
    fn dial(&self, addr: &str, port: u16) -> impl Future<Output = Result<Stream, String>> + Send;
}

/// The existing relay path (TURN or the cmux relay), whatever the link used before this crate.
pub trait RelayDial: Send + Sync {
    fn dial(&self) -> impl Future<Output = Result<Stream, String>> + Send;
}

pub struct Connected {
    pub route: Route,
    /// The visible change, when this link's route differs from the last one.
    pub change: Option<RouteChange>,
    pub stream: Stream,
    /// How long the dial that won took.
    pub took: Duration,
}

impl std::fmt::Debug for Connected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Connected")
            .field("route", &self.route)
            .field("change", &self.change)
            .field("took", &self.took)
            .finish_non_exhaustive()
    }
}

/// The longest the tailnet dial may take before the link falls back to the relay.
pub const TAILNET_DIAL_TIMEOUT: Duration = Duration::from_secs(3);

/// Dials `peer_host:port` over the tailnet when the route allows it, else (or when that dial fails
/// or times out) the relay. Every route change comes back in [`Connected::change`].
pub async fn connect<N: PhoneNode, R: RelayDial>(
    mode: Mode,
    node: Option<&N>,
    peer_host: &str,
    port: u16,
    relay: &R,
    tracker: &mut RouteTracker,
    tailnet_timeout: Duration,
) -> Result<Connected, String> {
    let state = node.map_or(NodeState::Stopped, |n| n.state());
    let peer = node.and_then(|n| n.peer(peer_host));
    let mut route = route_for(mode, state, peer.as_ref());
    if let (Route::Tailnet { addr }, Some(node)) = (&route, node) {
        let started = Instant::now();
        match tokio::time::timeout(tailnet_timeout, node.dial(addr, port)).await {
            Ok(Ok(stream)) => {
                let change = tracker.observe(route.clone());
                return Ok(Connected { route, change, stream, took: started.elapsed() });
            }
            Ok(Err(why)) => route = Route::Relay { why: RelayReason::DialFailed(why) },
            Err(_) => {
                route = Route::Relay {
                    why: RelayReason::DialFailed(format!("no answer in {} ms", tailnet_timeout.as_millis())),
                };
            }
        }
    }
    let started = Instant::now();
    let stream = relay.dial().await.map_err(|e| format!("relay: {e}"))?;
    let change = tracker.observe(route.clone());
    Ok(Connected { route, change, stream, took: started.elapsed() })
}
