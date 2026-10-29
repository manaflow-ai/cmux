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
    /// `vmBoundary`: this caller lets the peer run its remote chains' Claude
    /// Code without the platform sandbox, the VM being the boundary
    /// (`hub/vm_boundary.rs`). Never set by `peer_add`: a fleet tool writes it
    /// for a VM its registry says is a dedicated agent VM, and a Cloud link's
    /// lease carries it when the Cloud API said the caller owns that VM.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub vm_boundary: bool,
    /// `githubBroker`: this Mac lends the peer its `gh` login for the broker's fixed actions
    /// (`github_broker.rs`). Add Machine (`acpmux host enroll`) sets it for the person's own
    /// machine; a plain `peer_add` and a Cloud lease never do.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub github_broker: bool,
}
