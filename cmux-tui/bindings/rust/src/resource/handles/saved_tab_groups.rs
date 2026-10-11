//! Saved tab groups on a session handle: `saved_tab_group.list`,
//! `saved_tab_group.save`, `saved_tab_group.delete`, and
//! `saved_tab_group.reopen` (resource-api-v2.md, "State resources";
//! capability `state-resources-v1`).
//!
//! A saved group is personal state of the home session (`saved_…` state id,
//! one room): a record of a group's name, color, and members that outlives
//! its tabs. A live group stays linked to its record
//! (`TabGroupSnapshot::saved_tab_group_id`). The same records arrive on
//! `session.events` as `state_upsert` / `state_delete` changes of
//! `saved_tab_group`, and in `ResourceSnapshot.extra.state.saved_tab_groups`.
//!
//! The snapshots decode forward-compatibly: `color`, `kind`, and `engine`
//! are strings with their known values documented, and fields this SDK does
//! not know stay in `additional`.

use super::super::*;
use super::tab_groups::TabGroupSnapshot;
use super::workspace_groups::validate_state_id;
use crate::resource::model::deserialize_decimal;
use serde::Deserialize;
use std::collections::BTreeMap;

/// One member a saved group reopens.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct SavedTabMemberSnapshot {
    /// Known values: `terminal`, `browser`. Other values are future kinds.
    pub kind: String,
    pub name: Option<String>,
    /// Terminal working directory used when the member is reopened.
    pub cwd: Option<String>,
    pub url: Option<String>,
    /// Known values: `webkit`, `cef`.
    pub engine: Option<String>,
    pub browser_profile_id: Option<String>,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// One saved tab group.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct SavedTabGroupSnapshot {
    /// The record's state id; also the id of its state changes.
    pub id: String,
    /// The room whose bar shows the saved group.
    pub room_id: String,
    pub name: String,
    /// Known values: `grey`, `blue`, `red`, `yellow`, `green`, `pink`,
    /// `purple`, `cyan`, `orange`. Other values are future colors.
    pub color: String,
    pub members: Vec<SavedTabMemberSnapshot>,
    /// Position among the saved groups.
    pub index: u32,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub updated_at_ms: u64,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// What `saved_tab_group.reopen` restored: the live group linked to the
/// record (an already linked live group is returned unchanged).
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct SavedTabGroupReopenResult {
    pub saved_tab_group_id: String,
    pub tab_group: TabGroupSnapshot,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// What a state delete removed.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct StateDeleteResult {
    pub id: String,
    /// `false` when the record was already gone.
    pub deleted: bool,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

impl Session {
    /// Every saved tab group, in order.
    pub fn saved_tab_groups(&self) -> Result<Vec<SavedTabGroupSnapshot>> {
        self.read_saved_tab_groups(None)
    }

    /// The saved tab groups of one room, in order.
    pub fn saved_tab_groups_in_room(
        &self,
        room: impl Into<String>,
    ) -> Result<Vec<SavedTabGroupSnapshot>> {
        self.read_saved_tab_groups(Some(room.into()))
    }

    fn read_saved_tab_groups(&self, room: Option<String>) -> Result<Vec<SavedTabGroupSnapshot>> {
        if let Some(room) = &room {
            validate_state_id("room", room)?;
        }
        let params = self.params().optional_string("room", room);
        let rows = self.client.read(ops::SAVED_TAB_GROUP_LIST, params)?;
        wire::decode_exact(&rows, "saved tab groups")
    }

    /// Saves a live tab group into `room` (`None`: the default room) with a
    /// fresh idempotency key. Saving a linked group refreshes its record.
    pub fn save_tab_group(
        &self,
        group: impl Into<String>,
        room: Option<String>,
    ) -> Result<MutationResult<SavedTabGroupSnapshot>> {
        self.save_tab_group_with(group, room, MutationOptions::unique()?)
    }

    pub fn save_tab_group_with(
        &self,
        group: impl Into<String>,
        room: Option<String>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<SavedTabGroupSnapshot>> {
        let group = group.into();
        validate_state_id("tab group", &group)?;
        if let Some(room) = &room {
            validate_state_id("room", room)?;
        }
        let params = self.params().string("tab_group", group).optional_string("room", room);
        mutation_snapshot(
            self.client.mutate(ops::SAVED_TAB_GROUP_SAVE, params, mutation)?,
            "saved tab group",
        )
    }

    /// Deletes a saved record with a fresh idempotency key; a linked live
    /// group stays, unlinked.
    pub fn delete_saved_tab_group(
        &self,
        saved: impl Into<String>,
    ) -> Result<MutationResult<StateDeleteResult>> {
        self.delete_saved_tab_group_with(saved, MutationOptions::unique()?)
    }

    pub fn delete_saved_tab_group_with(
        &self,
        saved: impl Into<String>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<StateDeleteResult>> {
        let params = self.saved_tab_group_params(saved)?;
        mutation_snapshot(
            self.client.mutate(ops::SAVED_TAB_GROUP_DELETE, params, mutation)?,
            "state delete result",
        )
    }

    /// Reopens a saved group into `pane` (`None`: the focused pane) with a
    /// fresh idempotency key. A retry with the same key replays the result.
    pub fn reopen_saved_tab_group(
        &self,
        saved: impl Into<String>,
        pane: Option<PaneId>,
    ) -> Result<MutationResult<SavedTabGroupReopenResult>> {
        self.reopen_saved_tab_group_with(saved, pane, MutationOptions::unique()?)
    }

    pub fn reopen_saved_tab_group_with(
        &self,
        saved: impl Into<String>,
        pane: Option<PaneId>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<SavedTabGroupReopenResult>> {
        let params = self.saved_tab_group_params(saved)?.optional_id("pane_id", pane.as_ref());
        mutation_snapshot(
            self.client.mutate(ops::SAVED_TAB_GROUP_REOPEN, params, mutation)?,
            "saved tab group reopen result",
        )
    }

    fn saved_tab_group_params(&self, saved: impl Into<String>) -> Result<Params> {
        let saved = saved.into();
        validate_state_id("saved tab group", &saved)?;
        Ok(self.params().string("saved_tab_group", saved))
    }
}
