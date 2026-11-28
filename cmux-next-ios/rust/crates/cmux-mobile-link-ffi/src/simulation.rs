//! The debug network simulations of a dial (`ConnectOptions`: relay only, UDP blocked, proxy only,
//! WireGuard dropped, HTTPS relay only), each from the app's request or the rig's environment
//! (`CMUX_MOBILE_DEV_*`, which `review.sh`'s relay-only relaunch and the simulator soaks set).
//!
//! Read in one place so every path of a dial agrees: the relayed dial's options (`dial_options`), and
//! the two direct racers beside it, the enrolled LAN dial (`lan::race`) and the nearby Mac's hub dial
//! (`local_link::dial_local`). Each simulation is a network where the phone must not reach the Mac
//! directly, so both racers sit it out. Before, the LAN race read none of them and the hub dial only the
//! request's own fields: a phone with Local Network access, launched with `CMUX_MOBILE_DEV_RELAY_ONLY=1`,
//! linked over the LAN and the hand-off's relay-only check failed.

use crate::ConnectRequest;

/// One dial's network simulations (module docs).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct Simulation {
    /// Skip every direct path: TURN only (`CMUX_MOBILE_DEV_RELAY_ONLY`).
    pub relay_only: bool,
    /// No plain UDP and no TURN over UDP (`CMUX_MOBILE_DEV_BLOCK_UDP`); a proxy-only network too.
    pub block_udp: bool,
    /// Out only through the system's proxy (`CMUX_MOBILE_DEV_PROXY_ONLY`).
    pub proxy_only: bool,
    /// Every UDP datagram carrying WireGuard is dropped (`CMUX_MOBILE_DEV_DROP_WIREGUARD`).
    pub drop_wireguard: bool,
    /// cmux's WebSocket relay only (`CMUX_MOBILE_DEV_FORCE_RELAY`).
    pub force_relay: bool,
}

impl Simulation {
    /// `request`'s simulations, with the process environment's.
    pub(crate) fn of(request: &ConnectRequest) -> Self {
        Self::with_env(request, |name| std::env::var_os(name).is_some())
    }

    /// `request`'s simulations, with `set` saying whether an environment variable is set (tests pass
    /// their own, so they never touch the process environment).
    pub(crate) fn with_env(request: &ConnectRequest, set: impl Fn(&str) -> bool) -> Self {
        let proxy_only = request.proxy_only || set("CMUX_MOBILE_DEV_PROXY_ONLY");
        Self {
            relay_only: request.relay_only || set("CMUX_MOBILE_DEV_RELAY_ONLY"),
            block_udp: request.block_udp || set("CMUX_MOBILE_DEV_BLOCK_UDP") || proxy_only,
            proxy_only,
            drop_wireguard: request.drop_wireguard || set("CMUX_MOBILE_DEV_DROP_WIREGUARD"),
            force_relay: request.force_relay || set("CMUX_MOBILE_DEV_FORCE_RELAY"),
        }
    }

    /// Whether the direct racers (LAN, tailnet and the nearby hub) sit this dial out: any simulation
    /// is a network where the phone does not reach the Mac directly, and a direct link would hide the
    /// relayed path the simulation tests.
    pub(crate) fn direct_paths_off(self) -> bool {
        self.relay_only || self.block_udp || self.proxy_only || self.drop_wireguard || self.force_relay
    }
}

#[cfg(test)]
#[path = "simulation_tests.rs"]
mod tests;
