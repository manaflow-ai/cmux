//! The phone's own tailnet node: a userspace Tailscale (tsnet) node inside the iPhone app's process,
//! used only by cmux's own sockets.
//!
//! # The decision: (a) an in-app userspace node, with (b) the relay as the fallback
//!
//! Leo: "OpenAI doesn't ask you to use Tailscale", and (12:45Z) "perhaps we moreso have a single
//! stable one or a few per user, idk, and the rest underlying shifts beneath their feet with none
//! the wiser". So nobody installs the Tailscale app or grants a VPN profile for cmux:
//!
//! - **(a) In-app node.** libtailscale's tsnet runs in the app's own process, as the Mac's daemon
//!   already does (`cmux-tailnet`). It needs no NetworkExtension and no VPN entitlement (the App
//!   Review gate keeps banning both), routes nothing else on the phone, and joins the same tailnet
//!   as the person's Mac and stable per-user node. The phone dials the Mac's tailnet address
//!   directly, and the Mac's `transport.tailnetCarrier` listener admits only the same owner.
//! - **(b) The existing relay** stays the path whenever the node is off, not signed in, or the peer
//!   has no direct path. A route change is always reported ([`route::RouteTracker`]), never silent.
//!
//! Default off: the node only runs when `transport.tailnetCarrier` is not `off` and a key was
//! saved. Off is the default because the link through the relay works for everyone today, and
//! the iOS build of libtailscale (GOOS=ios c-archive) is built on a Mac, which this crate's Linux
//! proof does not cover.
//!
//! The pieces:
//! - [`Mode`]: the setting's value.
//! - [`route`]: which route a link takes, from the node's state and the peer's path.
//! - [`key`]: where a key lives (the app Keychain, this device only, one item per tailnet) and the
//!   advice the key sheet shows.
//! - [`connect`]: dial over the node, else the relay, behind the [`connect::PhoneNode`] trait.
//! - `tsnet` (feature `tsnet`): the real node over `cmux-tailnet`.

pub mod connect;
pub mod key;
pub mod route;
#[cfg(all(feature = "tsnet", unix))]
pub mod tsnet;

use serde::{Deserialize, Serialize};

/// `transport.tailnetCarrier`, read the same way the Mac reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Mode {
    /// No node, no tailnet candidate: the relay only. The default.
    #[default]
    Off,
    /// The node may carry a link only over a direct WireGuard path.
    DirectOnly,
    /// The carrier policy value. Like the Mac, DERP and peer-relay paths stay excluded until their
    /// cost is measured, so today it routes the same as `DirectOnly`.
    On,
}

impl Mode {
    /// The setting's text. Anything unknown (a newer value, a typo) is `Off`: never a tailnet path
    /// the person did not choose.
    pub fn from_setting(value: &str) -> Self {
        match value.trim() {
            "direct-only" => Self::DirectOnly,
            "on" => Self::On,
            _ => Self::Off,
        }
    }

    pub fn as_setting(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::DirectOnly => "direct-only",
            Self::On => "on",
        }
    }

    /// Whether the node should run at all.
    pub fn runs_node(self) -> bool {
        self != Self::Off
    }
}

#[cfg(test)]
mod tests;
