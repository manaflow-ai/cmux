//! The chat's copy going to the Cloud. Owned by slice B (the laptop daemon).
//!
//! - [`events`]: the chat's log records in order, from seq 1, appended in batches of at most
//!   256 and 1 MiB; a gap answer says where to resume.
//! - [`snapshot`]: the chat's folder as chunks ([`folder`]: `session_move_carry`'s git form, or
//!   a tar), its queue, draft and open turn in one manifest, posted after its events.
//! - [`native`]: the agent's own session files, in the same manifest, so the next holder's
//!   agent resumes with its memory.
//! - [`leftover`]: what the folder holds beyond the last snapshot the store acknowledged, once
//!   another holder runs the chat.
//! - [`apply`]: that patch going into the folder when the person says so, merged beside the
//!   folder so uncommitted work and the index stay as they are.
//!
//! [`copy`] is one whole copy, in the order the store needs: the events, then the snapshot that
//! covers them.

pub(crate) mod apply;
pub(crate) mod events;
pub(crate) mod folder;
mod ignore;
pub(crate) mod leftover;
pub(crate) mod native;
mod redact;
pub(crate) mod snapshot;

#[cfg(test)]
#[path = "export/ignore_tests.rs"]
mod ignore_tests;

use std::sync::Arc;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::wire::{Fence, OpenTool};

use crate::hub::{Hub, Session};

/// One copy that reached the store.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Copied {
    /// The store's last event.
    pub last_seq: u64,
    pub stored: snapshot::Stored,
}

/// Sends the events the store lacks (it has them through `after`), then a snapshot of the chat
/// as it is now. The error carries the store's last seq when the events got there and the
/// snapshot did not, so the next copy resumes after them.
pub(crate) async fn copy<C: AutoCloud>(
    hub: &Arc<Hub>,
    cloud: &C,
    session: &Arc<Session>,
    fence: &Fence,
    after: u64,
    tool: Option<OpenTool>,
    now: u64,
) -> Result<Copied, (Option<u64>, snapshot::Failed)> {
    // Capture the manifest's chat/native state before reading the event high-water mark. That
    // state is therefore no newer than the events the bounded upload will cover, even when a
    // running turn keeps appending while the upload is in flight.
    let captured = snapshot::capture(hub, session, tool).await.map_err(|failed| (None, failed))?;
    let last_seq = events::upload(hub, cloud, session, fence, after, captured.through)
        .await
        .map_err(|error| (None, snapshot::Failed::from(error)))?;
    let stored = snapshot::upload(cloud, session, fence, last_seq, captured, now)
        .await
        .map_err(|failed| (Some(last_seq), failed))?;
    Ok(Copied { last_seq, stored })
}
