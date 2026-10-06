//! Personal workspace groups and the personal sidebar order:
//! `workspace_group.create`, `workspace_group.update`, `workspace_group.move`,
//! `workspace_group.delete`, and `workspace_group.list` on a session handle,
//! `workspace.place` on a workspace handle, and `workspace.placement.list` on
//! a session handle.
//!
//! Groups and placements are personal state: the daemon keeps one order for
//! the user, not per session. Group ids are daemon state ids (`grp_…`). A
//! placement names its workspace by session registry id and durable
//! reference, plus the public workspace id when the workspace is a live one
//! of this session. The same snapshots arrive on `session.events` as
//! `state_upsert` changes of `workspace_group` and `workspace_placement`, and
//! in `ResourceSnapshot.extra.state`.

use super::super::*;
use serde::Deserialize;

/// Longest state id (`workspace_group`, `room`) the daemon accepts.
const STATE_ID_MAX_LEN: usize = 64;

/// One personal workspace group.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceGroupSnapshot {
    /// The group's state id; also the id of its state changes.
    pub id: String,
    /// The room the group belongs to.
    pub room_id: String,
    pub name: String,
    /// Palette token or `#RRGGBB[AA]`; `None` is no color.
    pub color: Option<String>,
    pub collapsed: bool,
    /// Position among all groups.
    pub index: u32,
    /// The index of the personal workspace the group shows right before in
    /// the sidebar (`personal-mixed-order-v1`), or `None` for after every
    /// loose workspace. Older daemons omit it.
    #[serde(default)]
    pub top_index: Option<u32>,
}

/// A session-qualified workspace in the personal order.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceRef {
    /// Registry id of the session that owns the workspace.
    pub session_id: String,
    /// Opaque durable workspace reference within that session.
    pub workspace_ref: String,
    /// Public id when the workspace belongs to this session and is live.
    pub workspace_id: Option<WorkspaceId>,
}

impl WorkspaceRef {
    /// The id of this workspace's `workspace_placement` state changes:
    /// `<session_id>/<workspace_ref>`.
    pub fn placement_id(&self) -> String {
        format!("{}/{}", self.session_id, self.workspace_ref)
    }
}

/// One workspace's place in the personal sidebar order.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WorkspacePlacementSnapshot {
    pub workspace: WorkspaceRef,
    /// Position in the personal sidebar order.
    pub index: u32,
    /// The workspace's personal group, or `None` when it is ungrouped.
    pub group_id: Option<String>,
    /// The room the workspace is pinned to, or `None` when it follows its
    /// session.
    pub room_id: Option<String>,
}

/// What `workspace_group.delete` removed: the group and the workspaces it
/// ungrouped.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceGroupDeleteResult {
    pub id: String,
    pub ungrouped: Vec<WorkspaceRef>,
}

/// Fields of `workspace_group.create`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WorkspaceGroupCreateOptions {
    pub name: String,
    /// Palette token or `#RRGGBB[AA]`.
    pub color: Option<String>,
    /// The daemon defaults to expanded.
    pub collapsed: Option<bool>,
    /// The room's state id; the daemon defaults to the default room.
    pub room: Option<String>,
    /// Position among all groups; the daemon defaults to the end.
    pub index: Option<u32>,
}

impl WorkspaceGroupCreateOptions {
    pub fn new(name: impl Into<String>) -> Self {
        Self { name: name.into(), ..Self::default() }
    }
}

/// Fields of `workspace_group.update`. `None` and `Update::Unchanged` omit a
/// field; `color: Update::Clear` sends `null`. At least one field changes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WorkspaceGroupUpdateOptions {
    pub name: Option<String>,
    /// Palette token or `#RRGGBB[AA]`.
    pub color: Update<String>,
    pub collapsed: Option<bool>,
    /// Moves the group to this room and pins its workspaces there.
    pub room: Option<String>,
    /// The group's place among the loose workspaces
    /// (`personal-mixed-order-v1`): `Set(i)` shows it right before the
    /// personal workspace at index `i`; `Clear` puts it after every loose
    /// workspace.
    pub top_index: Update<u32>,
}

/// Fields of `workspace.place`. `group: Update::Clear` ungroups the
/// workspace; `index` is its final position in the personal sidebar order.
/// At least one field changes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WorkspacePlaceOptions {
    pub group: Update<String>,
    pub index: Option<u32>,
}

impl Session {
    /// Every personal workspace group, in order.
    pub fn workspace_groups(&self) -> Result<Vec<WorkspaceGroupSnapshot>> {
        self.read_workspace_groups(None)
    }

    /// The personal workspace groups of one room, in order.
    pub fn workspace_groups_in_room(
        &self,
        room: impl Into<String>,
    ) -> Result<Vec<WorkspaceGroupSnapshot>> {
        self.read_workspace_groups(Some(room.into()))
    }

    fn read_workspace_groups(&self, room: Option<String>) -> Result<Vec<WorkspaceGroupSnapshot>> {
        if let Some(room) = &room {
            validate_state_id("room", room)?;
        }
        let params = self.params().optional_string("room", room);
        let rows = self.client.read(ops::WORKSPACE_GROUP_LIST, params)?;
        wire::decode_exact(&rows, "workspace groups")
    }

    /// Every placement in the personal sidebar order. Live workspaces of this
    /// session without a personal row follow, ungrouped.
    pub fn workspace_placements(&self) -> Result<Vec<WorkspacePlacementSnapshot>> {
        let rows = self.client.read(ops::WORKSPACE_PLACEMENT_LIST, self.params())?;
        wire::decode_exact(&rows, "workspace placements")
    }

    /// Creates a personal workspace group with a fresh idempotency key.
    pub fn create_workspace_group(
        &self,
        options: WorkspaceGroupCreateOptions,
    ) -> Result<MutationResult<WorkspaceGroupSnapshot>> {
        self.create_workspace_group_with(options, MutationOptions::unique()?)
    }

    pub fn create_workspace_group_with(
        &self,
        options: WorkspaceGroupCreateOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WorkspaceGroupSnapshot>> {
        let WorkspaceGroupCreateOptions { name, color, collapsed, room, index } = options;
        if let Some(room) = &room {
            validate_state_id("room", room)?;
        }
        let params = self
            .params()
            .string(field::NAME, name)
            .optional_string("color", color)
            .optional_bool("collapsed", collapsed)
            .optional_string("room", room)
            .optional_u32(field::INDEX, index);
        mutation_snapshot(
            self.client.mutate(ops::WORKSPACE_GROUP_CREATE, params, mutation)?,
            "workspace group",
        )
    }

    /// Renames, recolors, collapses, or moves a group to another room with a
    /// fresh idempotency key.
    pub fn update_workspace_group(
        &self,
        group: impl Into<String>,
        options: WorkspaceGroupUpdateOptions,
    ) -> Result<MutationResult<WorkspaceGroupSnapshot>> {
        self.update_workspace_group_with(group, options, MutationOptions::unique()?)
    }

    pub fn update_workspace_group_with(
        &self,
        group: impl Into<String>,
        options: WorkspaceGroupUpdateOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WorkspaceGroupSnapshot>> {
        let WorkspaceGroupUpdateOptions { name, color, collapsed, room, top_index } = options;
        if name.is_none()
            && matches!(color, Update::Unchanged)
            && collapsed.is_none()
            && room.is_none()
            && matches!(top_index, Update::Unchanged)
        {
            return Err(Error::InvalidArgument(
                "workspace group update must change name, color, collapsed, room, or top_index"
                    .to_string(),
            ));
        }
        if let Some(room) = &room {
            validate_state_id("room", room)?;
        }
        let params = self
            .group_params(group)?
            .optional_string(field::NAME, name)
            .optional_bool("collapsed", collapsed)
            .optional_string("room", room);
        let params = match color {
            Update::Unchanged => params,
            Update::Clear => params.value("color", Value::Null),
            Update::Set(color) => params.string("color", color),
        };
        let params = match top_index {
            Update::Unchanged => params,
            Update::Clear => params.value("top_index", Value::Null),
            Update::Set(index) => params.u32("top_index", index),
        };
        mutation_snapshot(
            self.client.mutate(ops::WORKSPACE_GROUP_UPDATE, params, mutation)?,
            "workspace group",
        )
    }

    /// Moves a group to `index` among all groups (the insertion index before
    /// removal, like `workspace.move`) with a fresh idempotency key.
    pub fn move_workspace_group(
        &self,
        group: impl Into<String>,
        index: u32,
    ) -> Result<MutationResult<WorkspaceGroupSnapshot>> {
        self.move_workspace_group_with(group, index, MutationOptions::unique()?)
    }

    pub fn move_workspace_group_with(
        &self,
        group: impl Into<String>,
        index: u32,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WorkspaceGroupSnapshot>> {
        let params = self.group_params(group)?.u32(field::INDEX, index);
        mutation_snapshot(
            self.client.mutate(ops::WORKSPACE_GROUP_MOVE, params, mutation)?,
            "workspace group",
        )
    }

    /// Deletes a group with a fresh idempotency key; its workspaces stay and
    /// become ungrouped.
    pub fn delete_workspace_group(
        &self,
        group: impl Into<String>,
    ) -> Result<MutationResult<WorkspaceGroupDeleteResult>> {
        self.delete_workspace_group_with(group, MutationOptions::unique()?)
    }

    pub fn delete_workspace_group_with(
        &self,
        group: impl Into<String>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WorkspaceGroupDeleteResult>> {
        let params = self.group_params(group)?;
        mutation_snapshot(
            self.client.mutate(ops::WORKSPACE_GROUP_DELETE, params, mutation)?,
            "workspace group delete result",
        )
    }

    fn group_params(&self, group: impl Into<String>) -> Result<Params> {
        let group = group.into();
        validate_state_id("workspace group", &group)?;
        Ok(self.params().string("workspace_group", group))
    }
}

impl Workspace {
    /// Puts this workspace into a personal group (or out of one) and/or at a
    /// final position in the personal sidebar order, with a fresh
    /// idempotency key.
    pub fn place(
        &self,
        options: WorkspacePlaceOptions,
    ) -> Result<MutationResult<WorkspacePlacementSnapshot>> {
        self.place_with(options, MutationOptions::unique()?)
    }

    pub fn place_with(
        &self,
        options: WorkspacePlaceOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WorkspacePlacementSnapshot>> {
        let WorkspacePlaceOptions { group, index } = options;
        let params = match group {
            Update::Unchanged if index.is_none() => {
                return Err(Error::InvalidArgument(
                    "workspace place must change group or index".to_string(),
                ));
            }
            Update::Unchanged => self.params(),
            Update::Clear => self.params().value("group", Value::Null),
            Update::Set(group) => {
                validate_state_id("workspace group", &group)?;
                self.params().string("group", group)
            }
        };
        let params = params.optional_u32(field::INDEX, index);
        mutation_snapshot(
            self.session.client.mutate(ops::WORKSPACE_PLACE, params, mutation)?,
            "workspace placement",
        )
    }
}

/// A state id is 1 to 64 characters.
pub(super) fn validate_state_id(label: &str, value: &str) -> Result<()> {
    if value.is_empty() || value.chars().count() > STATE_ID_MAX_LEN {
        return Err(Error::InvalidArgument(format!(
            "{label} id must be 1 to {STATE_ID_MAX_LEN} characters"
        )));
    }
    Ok(())
}
