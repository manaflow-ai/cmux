// Stub: the peering branch replaces this file.
//! The `peer`, `peer-back` and `identity` steps of `host enroll` and
//! `host doctor`.

use crate::cli::host_steps::{Step, StepResult, StepState};
use crate::client::Client;

/// The machine a peering step works on, and this machine as it sees it.
pub struct PeerTarget<'a> {
    pub name: &'a str,
    pub host: &'a str,
    pub local_name: &'a str,
    pub local_dest: Option<&'a str>,
}

pub async fn peer(_client: &Client, _t: &PeerTarget<'_>, _fix: bool) -> StepResult {
    StepResult::new(Step::Peer, StepState::Skip, "not built yet")
}

pub async fn peer_back(_t: &PeerTarget<'_>, _fix: bool) -> StepResult {
    StepResult::new(Step::PeerBack, StepState::Skip, "not built yet")
}

pub async fn identity(_client: &Client, _t: &PeerTarget<'_>, _fix: bool) -> StepResult {
    StepResult::new(Step::Identity, StepState::Skip, "not built yet")
}
