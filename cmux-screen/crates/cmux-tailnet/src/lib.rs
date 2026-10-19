//! This cmux install as its own device on the user's tailnet.
//!
//! The node is Tailscale's own tsnet, linked as libtailscale (BSD-3-Clause),
//! so a machine needs no Tailscale app: the node signs in once (a browser
//! link, or a one-time auth key for headless hosts), keeps its login in
//! `state_dir`, and gets a MagicDNS name such as
//! `cmux-studio.<tailnet>.ts.net`.
//!
//! What this crate gives the rest of cmux:
//! - [`Node`]: start, sign-in state as events ([`Node::watch`], no polling),
//!   TCP listen and dial on the tailnet, and WhoIs for a peer address;
//! - [`Access`]: who may connect (default: the node's owner only), checked
//!   on the WhoIs answer before any application byte is read.
//!
//! The network decides reachability (Tailscale ACLs); [`Access`] decides
//! which identities this host serves; the application's own gates (for the
//! screen host: no browser origins, then the consent prompt) come after both.

mod access;
mod ffi;
mod localapi;
mod node;
mod types;

pub use access::{Access, Decision};
pub use localapi::Watch;
pub use node::{Listener, Node, NodeConfig};
pub use types::{BackendState, Notify, PeerStatus, Status, TailnetInfo, UserProfile, WhoIs, WhoIsNode};

/// An error from libtailscale or the node's LocalAPI.
#[derive(Debug)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;
