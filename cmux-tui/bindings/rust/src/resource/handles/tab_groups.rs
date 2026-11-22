//! Tab groups on a session handle: `tab_group.list`, `tab_group.get`,
//! `tab_group.create`, `tab_group.update`, `tab_group.add_tabs`,
//! `tab_group.remove_tabs`, `tab_group.move`, `tab_group.ungroup`, and
//! `tab_group.close` (resource-api-v2.md, "State resources"; capability
//! `state-resources-v1`).
//!
//! A tab group is shared state of the session: a named, colored run of
//! contiguous tabs of one pane (`tgrp_…` state id). Every mutation takes an
//! idempotency key, so a retry after a lost response replays. The same
//! groups arrive on `session.events` as `state_upsert` / `state_delete`
//! changes of `tab_group`, and in `ResourceSnapshot.extra.state.tab_groups`;
//! a member tab carries `extra.tab_group_id`.
//!
//! The raw `*-tab-group` commands remain for the moves the resource API does
//! not have (into a split, a new column, or a new workspace).
//!
//! The snapshots decode forward-compatibly: `color` is a string with its
//! known values documented, and fields this SDK does not know stay in
//! `additional`.

use super::super::*;
use super::workspace_groups::validate_state_id;
use serde::Deserialize;
use std::collections::BTreeMap;

/// Most tabs one tab group request names.
pub const TAB_GROUP_MAX_TABS: usize = 256;

/// One live tab group.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct TabGroupSnapshot {
    /// The group's state id; also the id of its state changes.
    pub id: String,
    pub pane_id: PaneId,
    /// May be empty: the group shows only its color.
    pub name: String,
    /// Known values: `grey`, `blue`, `red`, `yellow`, `green`, `pink`,
    /// `purple`, `cyan`, `orange`. Other values are future colors.
    pub color: String,
    pub collapsed: bool,
    /// Members in strip order; they are contiguous.
    pub tab_ids: Vec<TabId>,
    /// The saved group this live group syncs with.
    pub saved_tab_group_id: Option<String>,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// The former members `tab_group.ungroup` or `tab_group.close` released.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct TabGroupReleaseResult {
    pub tab_group_id: String,
    /// Ungrouped tabs, or the tabs a close removed.
    pub tab_ids: Vec<TabId>,
    #[serde(flatten)]
    pub additional: BTreeMap<String, Value>,
}

/// Fields of `tab_group.create`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TabGroupCreateOptions {
    /// Tabs of one pane; they become contiguous at the first member's
    /// position. Pinned tabs cannot be grouped.
    pub tabs: Vec<TabId>,
    pub name: Option<String>,
    /// A group color (see [`TabGroupSnapshot::color`]); the daemon defaults
    /// to `grey`.
    pub color: Option<String>,
}

impl TabGroupCreateOptions {
    pub fn new(tabs: Vec<TabId>) -> Self {
        Self { tabs, ..Self::default() }
    }
}

/// Fields of `tab_group.update`. At least one field changes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TabGroupUpdateOptions {
    pub name: Option<String>,
    /// A group color (see [`TabGroupSnapshot::color`]).
    pub color: Option<String>,
    pub collapsed: Option<bool>,
}

/// Fields of `tab_group.move`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TabGroupMoveOptions {
    /// Destination pane; the daemon defaults to the group's own pane.
    pub pane: Option<PaneId>,
    /// Insertion index among the destination pane's other tabs; the daemon
    /// defaults to the end.
    pub index: Option<u32>,
}

impl Session {
    /// Every live tab group of the session.
    pub fn tab_groups(&self) -> Result<Vec<TabGroupSnapshot>> {
        self.read_tab_groups(None)
    }

    /// The live tab groups of one pane.
    pub fn tab_groups_in_pane(&self, pane: &PaneId) -> Result<Vec<TabGroupSnapshot>> {
        self.read_tab_groups(Some(pane))
    }

    fn read_tab_groups(&self, pane: Option<&PaneId>) -> Result<Vec<TabGroupSnapshot>> {
        let rows =
            self.client.read(ops::TAB_GROUP_LIST, self.params().optional_id("pane_id", pane))?;
        wire::decode_exact(&rows, "tab groups")
    }

    /// One live tab group by state id.
    pub fn tab_group(&self, group: impl Into<String>) -> Result<TabGroupSnapshot> {
        let value = self.client.read(ops::TAB_GROUP_GET, self.tab_group_params(group)?)?;
        wire::snapshot(&value, "tab group")
    }

    /// Groups tabs of one pane with a fresh idempotency key.
    pub fn create_tab_group(
        &self,
        options: TabGroupCreateOptions,
    ) -> Result<MutationResult<TabGroupSnapshot>> {
        self.create_tab_group_with(options, MutationOptions::unique()?)
    }

    pub fn create_tab_group_with(
        &self,
        options: TabGroupCreateOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TabGroupSnapshot>> {
        let TabGroupCreateOptions { tabs, name, color } = options;
        let params = self
            .params()
            .value("tabs", tab_ids(&tabs)?)
            .optional_string(field::NAME, name)
            .optional_string("color", color);
        mutation_snapshot(self.client.mutate(ops::TAB_GROUP_CREATE, params, mutation)?, "tab group")
    }

    /// Renames, recolors, collapses, or expands a group with a fresh
    /// idempotency key. A linked saved group follows.
    pub fn update_tab_group(
        &self,
        group: impl Into<String>,
        options: TabGroupUpdateOptions,
    ) -> Result<MutationResult<TabGroupSnapshot>> {
        self.update_tab_group_with(group, options, MutationOptions::unique()?)
    }

    pub fn update_tab_group_with(
        &self,
        group: impl Into<String>,
        options: TabGroupUpdateOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TabGroupSnapshot>> {
        let TabGroupUpdateOptions { name, color, collapsed } = options;
        if name.is_none() && color.is_none() && collapsed.is_none() {
            return Err(Error::InvalidArgument(
                "tab group update must change name, color, or collapsed".to_string(),
            ));
        }
        let params = self
            .tab_group_params(group)?
            .optional_string(field::NAME, name)
            .optional_string("color", color)
            .optional_bool("collapsed", collapsed);
        mutation_snapshot(self.client.mutate(ops::TAB_GROUP_UPDATE, params, mutation)?, "tab group")
    }

    /// Adds tabs to a group at `index` inside it (`None`: the end) with a
    /// fresh idempotency key. Tabs of other panes move into the group's pane.
    pub fn add_tabs_to_tab_group(
        &self,
        group: impl Into<String>,
        tabs: Vec<TabId>,
        index: Option<u32>,
    ) -> Result<MutationResult<TabGroupSnapshot>> {
        self.add_tabs_to_tab_group_with(group, tabs, index, MutationOptions::unique()?)
    }

    pub fn add_tabs_to_tab_group_with(
        &self,
        group: impl Into<String>,
        tabs: Vec<TabId>,
        index: Option<u32>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TabGroupSnapshot>> {
        let params = self
            .tab_group_params(group)?
            .value("tabs", tab_ids(&tabs)?)
            .optional_u32(field::INDEX, index);
        mutation_snapshot(
            self.client.mutate(ops::TAB_GROUP_ADD_TABS, params, mutation)?,
            "tab group",
        )
    }

    /// Takes tabs out of their groups with a fresh idempotency key; each
    /// lands right after its former group. Returns the groups that changed.
    pub fn remove_tabs_from_tab_groups(
        &self,
        tabs: Vec<TabId>,
    ) -> Result<MutationResult<Vec<TabGroupSnapshot>>> {
        self.remove_tabs_from_tab_groups_with(tabs, MutationOptions::unique()?)
    }

    pub fn remove_tabs_from_tab_groups_with(
        &self,
        tabs: Vec<TabId>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<Vec<TabGroupSnapshot>>> {
        let params = self.params().value("tabs", tab_ids(&tabs)?);
        mutation_snapshot(
            self.client.mutate(ops::TAB_GROUP_REMOVE_TABS, params, mutation)?,
            "tab groups",
        )
    }

    /// Moves a whole group, members in order, with a fresh idempotency key.
    pub fn move_tab_group(
        &self,
        group: impl Into<String>,
        options: TabGroupMoveOptions,
    ) -> Result<MutationResult<TabGroupSnapshot>> {
        self.move_tab_group_with(group, options, MutationOptions::unique()?)
    }

    pub fn move_tab_group_with(
        &self,
        group: impl Into<String>,
        options: TabGroupMoveOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TabGroupSnapshot>> {
        let TabGroupMoveOptions { pane, index } = options;
        let params = self
            .tab_group_params(group)?
            .optional_id("pane_id", pane.as_ref())
            .optional_u32(field::INDEX, index);
        mutation_snapshot(self.client.mutate(ops::TAB_GROUP_MOVE, params, mutation)?, "tab group")
    }

    /// Deletes a group with a fresh idempotency key; its tabs stay in place.
    pub fn ungroup_tab_group(
        &self,
        group: impl Into<String>,
    ) -> Result<MutationResult<TabGroupReleaseResult>> {
        self.ungroup_tab_group_with(group, MutationOptions::unique()?)
    }

    pub fn ungroup_tab_group_with(
        &self,
        group: impl Into<String>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TabGroupReleaseResult>> {
        let params = self.tab_group_params(group)?;
        mutation_snapshot(
            self.client.mutate(ops::TAB_GROUP_UNGROUP, params, mutation)?,
            "tab group release result",
        )
    }

    /// Closes every member tab with a fresh idempotency key. A linked saved
    /// group keeps its record.
    pub fn close_tab_group(
        &self,
        group: impl Into<String>,
    ) -> Result<MutationResult<TabGroupReleaseResult>> {
        self.close_tab_group_with(group, MutationOptions::unique()?)
    }

    pub fn close_tab_group_with(
        &self,
        group: impl Into<String>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TabGroupReleaseResult>> {
        let params = self.tab_group_params(group)?;
        mutation_snapshot(
            self.client.mutate(ops::TAB_GROUP_CLOSE, params, mutation)?,
            "tab group release result",
        )
    }

    fn tab_group_params(&self, group: impl Into<String>) -> Result<Params> {
        let group = group.into();
        validate_state_id("tab group", &group)?;
        Ok(self.params().string("tab_group", group))
    }
}

/// The `tabs` array: 1 to [`TAB_GROUP_MAX_TABS`] tab ids.
fn tab_ids(tabs: &[TabId]) -> Result<Value> {
    if tabs.is_empty() || tabs.len() > TAB_GROUP_MAX_TABS {
        return Err(Error::InvalidArgument(format!(
            "a tab group request names 1 to {TAB_GROUP_MAX_TABS} tabs"
        )));
    }
    Ok(Value::from(tabs.iter().map(|tab| tab.as_str().to_string()).collect::<Vec<_>>()))
}
