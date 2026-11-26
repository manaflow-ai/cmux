//! Which route a cmux link takes: the tailnet when the node runs and the peer has a direct path,
//! else the relay, with the reason. Pure, so every combination is a unit test.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::Mode;

/// The phone node's state, reduced to what routing needs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum NodeState {
    /// Not started (setting off, or no key saved).
    Stopped,
    /// Started, not yet Running (signing in, waiting for the control server).
    Starting,
    /// The control server wants a new key (expired, revoked, or the node was deleted).
    NeedsLogin,
    Running,
}

/// What the node knows about the peer (the Mac, or the stable per-user node).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerPath {
    /// The peer's tailnet address the link dials ("100.64.0.2").
    pub addr: String,
    /// The control server reports it connected.
    pub online: bool,
    /// The path is a direct WireGuard endpoint, not DERP or a peer relay.
    pub direct: bool,
}

/// Why the link uses the relay.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "reason", content = "detail", rename_all = "kebab-case")]
pub enum RelayReason {
    SettingOff,
    NodeStopped,
    NodeStarting,
    NeedsLogin,
    PeerNotOnTailnet,
    PeerOffline,
    /// The tailnet path rides DERP or a peer relay: excluded until its cost is measured.
    PeerNotDirect,
    /// The tailnet dial itself failed or timed out (the text never holds a key).
    DialFailed(String),
}

impl fmt::Display for RelayReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SettingOff => f.write_str("the Tailscale carrier is off"),
            Self::NodeStopped => f.write_str("the phone's tailnet node is not running"),
            Self::NodeStarting => f.write_str("the phone's tailnet node is still signing in"),
            Self::NeedsLogin => f.write_str("the tailnet wants a new key"),
            Self::PeerNotOnTailnet => f.write_str("the Mac is not on this tailnet"),
            Self::PeerOffline => f.write_str("the Mac is offline on the tailnet"),
            Self::PeerNotDirect => f.write_str("the tailnet path to the Mac is relayed, not direct"),
            Self::DialFailed(why) => write!(f, "the tailnet dial failed: {why}"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "route", rename_all = "kebab-case")]
pub enum Route {
    Tailnet { addr: String },
    Relay { why: RelayReason },
}

impl fmt::Display for Route {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Tailnet { addr } => write!(f, "direct over the tailnet ({addr})"),
            Self::Relay { why } => write!(f, "the relay ({why})"),
        }
    }
}

/// The route for one link. `peer` is None when the node sees no such peer.
pub fn route_for(mode: Mode, state: NodeState, peer: Option<&PeerPath>) -> Route {
    let relay = |why| Route::Relay { why };
    if mode == Mode::Off {
        return relay(RelayReason::SettingOff);
    }
    match state {
        NodeState::Stopped => return relay(RelayReason::NodeStopped),
        NodeState::Starting => return relay(RelayReason::NodeStarting),
        NodeState::NeedsLogin => return relay(RelayReason::NeedsLogin),
        NodeState::Running => {}
    }
    let Some(peer) = peer else {
        return relay(RelayReason::PeerNotOnTailnet);
    };
    if !peer.online {
        return relay(RelayReason::PeerOffline);
    }
    // DirectOnly and On both exclude relayed tailnet paths today (the setting's note).
    if !peer.direct {
        return relay(RelayReason::PeerNotDirect);
    }
    Route::Tailnet { addr: peer.addr.clone() }
}

/// A route change the app shows (the link's transport line) and logs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteChange {
    pub from: Option<Route>,
    pub to: Route,
}

impl fmt::Display for RouteChange {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.from {
            None => write!(f, "link: {}", self.to),
            Some(from) => write!(f, "link moved from {from} to {}", self.to),
        }
    }
}

/// Remembers the current route so every change comes back as a [`RouteChange`]: a route never
/// changes silently.
#[derive(Debug, Default)]
pub struct RouteTracker {
    current: Option<Route>,
}

impl RouteTracker {
    pub fn current(&self) -> Option<&Route> {
        self.current.as_ref()
    }

    /// Records `route`; returns the change, or None when it is the route already in use.
    pub fn observe(&mut self, route: Route) -> Option<RouteChange> {
        if self.current.as_ref() == Some(&route) {
            return None;
        }
        let from = self.current.replace(route.clone());
        let change = RouteChange { from, to: route };
        tracing::info!(target: "cmux_mobile_tailnet", "{change}");
        Some(change)
    }
}
