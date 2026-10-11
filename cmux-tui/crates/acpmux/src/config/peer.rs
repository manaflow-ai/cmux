//! `peers` in config.json: the remote daemons this daemon mirrors.

use serde::{Deserialize, Serialize};

/// A remote acpmux daemon this daemon mirrors. Sessions there appear here as
/// `<peer>/<name>` and every request is forwarded.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PeerConfig {
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    /// The peer daemon's peer token (`server/peer_auth.rs`), for a `ws://`
    /// or `wss://` peer; an `ssh://` peer reads it over ssh at each connect.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_token: Option<String>,
}
