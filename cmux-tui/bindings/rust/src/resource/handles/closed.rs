//! Closed history on a session handle: `closed.list` and `closed.reopen`
//! (resource-api-v2.md, "State resources"; capability `state-resources-v1`).
//!
//! One close gesture is one group (`closed_…` state id); reopen restores its
//! members in order, all of them or the chosen `members`. The same groups
//! arrive on `session.events` as `state_upsert` / `state_delete` changes of
//! `closed`, and in `ResourceSnapshot.extra.state.closed`.
//!
//! The snapshots decode forward-compatibly: `kind` is a string with its known
//! values documented, and fields this SDK does not know stay in
//! `additional`.

use super::super::*;
use super::workspace_groups::validate_state_id;
use crate::resource::model::deserialize_decimal;
use serde::Deserialize;
use std::collections::BTreeMap;

/// Most groups `closed.list` returns.
const CLOSED_LIST_MAX: u32 = 1000;
/// Longest window record id (`install_id/window_id`).
const WINDOW_ID_MAX_LEN: usize = 257;

/// One tab a closed screen recreates.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct ClosedTabRecord {
    /// Known values: `terminal`, `browser`. Other values are future kinds.
    pub kind: String,
    pub name: Option<String>,
    pub cwd: Option<String>,
    pub url: Option<String>,
    pub browser_profile_id: Option<String>,
    pub pinned: bool,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// One screen a closed item recreates.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct ClosedScreenRecord {
    pub name: Option<String>,
    pub tabs: Vec<ClosedTabRecord>,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// One closed object of a group.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct ClosedMemberRecord {
    /// Known values: `tab`, `screen`, `workspace`. Other values are future
    /// kinds.
    pub kind: String,
    /// Tab, screen, or workspace name at close.
    pub name: Option<String>,
    /// The workspace a tab or screen was closed from.
    pub workspace_id: Option<WorkspaceId>,
    /// The pane a tab was closed from.
    pub pane_id: Option<PaneId>,
    /// Position the object held when it closed.
    pub index: u32,
    /// What reopen recreates; a closed tab has one screen with one tab.
    pub screens: Vec<ClosedScreenRecord>,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// One closed group (one close gesture). The top-level `name`,
/// `workspace_id`, `pane_id`, `index`, and `screens` mirror the first member.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct ClosedItemSnapshot {
    /// The group's state id (`closed_…`); also the id of its state changes.
    pub id: String,
    /// Known values: `tab`, `screen`, `workspace`. Other values are future
    /// kinds.
    pub kind: String,
    pub name: Option<String>,
    pub workspace_id: Option<WorkspaceId>,
    pub pane_id: Option<PaneId>,
    pub index: u32,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub closed_at_ms: u64,
    pub screens: Vec<ClosedScreenRecord>,
    /// Window record id (`install_id/window_id`) that listed the closed
    /// objects; `None` when no window listed them.
    pub window: Option<String>,
    pub member_count: u32,
    /// Every closed object of the group in restore order.
    pub members: Vec<ClosedMemberRecord>,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// What `closed.reopen` restored.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct ClosedReopenResult {
    pub closed_id: String,
    /// Known values: `tab`, `screen`, `workspace`.
    pub kind: String,
    /// The first of `workspace_ids`.
    pub workspace_id: WorkspaceId,
    /// Every workspace the reopened members went to.
    pub workspace_ids: Vec<WorkspaceId>,
    /// Members still in the group after a partial reopen.
    pub remaining: u32,
    pub screen_ids: Vec<ScreenId>,
    pub tab_ids: Vec<TabId>,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// Fields of `closed.list`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ClosedListOptions {
    /// The caller's window record id (`install_id/window_id`): only that
    /// window's groups and groups no live window owns.
    pub window: Option<String>,
    /// Newest groups to return, 1 to 1000; the daemon defaults to 100.
    pub limit: Option<u32>,
}

/// Fields of `closed.reopen`. With no `closed`, the daemon reopens the
/// newest group of `window`, else the newest group no live window owns.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ClosedReopenOptions {
    /// The group's state id.
    pub closed: Option<String>,
    /// The caller's window record id (`install_id/window_id`).
    pub window: Option<String>,
    /// Indexes into the group's `members`; `None` reopens every member, and
    /// the rest stay in the group.
    pub members: Option<Vec<u32>>,
}

impl Session {
    /// The newest closed groups, newest first.
    pub fn closed_items(&self, options: ClosedListOptions) -> Result<Vec<ClosedItemSnapshot>> {
        let ClosedListOptions { window, limit } = options;
        validate_window(window.as_deref())?;
        if let Some(limit) = limit
            && !(1..=CLOSED_LIST_MAX).contains(&limit)
        {
            return Err(Error::InvalidArgument(format!(
                "closed list limit must be 1 to {CLOSED_LIST_MAX}"
            )));
        }
        let params = self.params().optional_string("window", window).optional_u32("limit", limit);
        let rows = self.client.read(ops::CLOSED_LIST, params)?;
        wire::decode_exact(&rows, "closed items")
    }

    /// Reopens a closed group (or some of its members) with a fresh
    /// idempotency key. A retry with the same key replays the whole result.
    pub fn reopen_closed(
        &self,
        options: ClosedReopenOptions,
    ) -> Result<MutationResult<ClosedReopenResult>> {
        self.reopen_closed_with(options, MutationOptions::unique()?)
    }

    pub fn reopen_closed_with(
        &self,
        options: ClosedReopenOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<ClosedReopenResult>> {
        let ClosedReopenOptions { closed, window, members } = options;
        if let Some(closed) = &closed {
            validate_state_id("closed", closed)?;
        }
        validate_window(window.as_deref())?;
        let mut params =
            self.params().optional_string("closed", closed).optional_string("window", window);
        if let Some(members) = members {
            if members.is_empty() || members.len() > CLOSED_LIST_MAX as usize {
                return Err(Error::InvalidArgument(format!(
                    "closed reopen members must name 1 to {CLOSED_LIST_MAX} indexes"
                )));
            }
            params = params.value("members", Value::from(members));
        }
        mutation_snapshot(
            self.client.mutate(ops::CLOSED_REOPEN, params, mutation)?,
            "closed reopen result",
        )
    }
}

fn validate_window(window: Option<&str>) -> Result<()> {
    match window {
        Some(window) if window.is_empty() || window.len() > WINDOW_ID_MAX_LEN => {
            Err(Error::InvalidArgument(format!(
                "window record id must be 1 to {WINDOW_ID_MAX_LEN} bytes"
            )))
        }
        _ => Ok(()),
    }
}
