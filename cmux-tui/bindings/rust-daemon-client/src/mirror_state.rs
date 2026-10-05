//! The personal state resources the mirror keeps: workspace groups and
//! workspace placements (the personal sidebar order).
//!
//! The daemon sends them in `ResourceSnapshot.extra.state` (arrays
//! `workspace_groups` and `workspace_placements`) and on `session.events` as
//! `state_upsert` / `state_delete` changes. The SDK decodes those changes as
//! `ResourceChange::Unknown`, keeping the raw object; this module decodes
//! that object into the SDK's typed snapshots. Other state resources (tab
//! groups, rooms, closed items, window records, ...) are named but not kept.

use cmux::{Document, WorkspaceGroupSnapshot, WorkspacePlacementSnapshot};
use serde_json::Value;
use std::collections::BTreeMap;

use crate::mirror::MirrorError;

/// The `resource` of a workspace group state change.
pub(crate) const WORKSPACE_GROUP: &str = "workspace_group";
/// The `resource` of a workspace placement state change.
pub(crate) const WORKSPACE_PLACEMENT: &str = "workspace_placement";

/// One decoded state change.
#[derive(Debug)]
pub(crate) enum StateChange {
    GroupUpsert(String, WorkspaceGroupSnapshot),
    GroupDelete(String),
    PlacementUpsert(String, WorkspacePlacementSnapshot),
    PlacementDelete(String),
    /// A state resource the mirror does not keep.
    Other(String),
}

fn invalid(resource: &str, reason: impl Into<String>) -> MirrorError {
    MirrorError::InvalidState { resource: resource.to_string(), reason: reason.into() }
}

/// Decodes an unknown change of kind `kind`. `Ok(None)`: not a state change.
pub(crate) fn decode(kind: &str, raw: &Document) -> Result<Option<StateChange>, MirrorError> {
    let upsert = match kind {
        "state_upsert" => true,
        "state_delete" => false,
        _ => return Ok(None),
    };
    let raw: Value = raw.deserialize().map_err(|e| invalid(kind, e.to_string()))?;
    let resource = raw
        .get("resource")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(kind, "no resource"))?
        .to_string();
    let id = raw
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .ok_or_else(|| invalid(&resource, "no id"))?
        .to_string();
    let value = || raw.get("value").cloned().ok_or_else(|| invalid(&resource, "no value"));
    Ok(Some(match (resource.as_str(), upsert) {
        (WORKSPACE_GROUP, true) => {
            let group: WorkspaceGroupSnapshot =
                serde_json::from_value(value()?).map_err(|e| invalid(&resource, e.to_string()))?;
            if group.id != id {
                return Err(invalid(&resource, format!("value id {} is not {id}", group.id)));
            }
            StateChange::GroupUpsert(id, group)
        }
        (WORKSPACE_GROUP, false) => StateChange::GroupDelete(id),
        (WORKSPACE_PLACEMENT, true) => {
            let placement: WorkspacePlacementSnapshot =
                serde_json::from_value(value()?).map_err(|e| invalid(&resource, e.to_string()))?;
            let expected = placement.workspace.placement_id();
            if expected != id {
                return Err(invalid(&resource, format!("value names {expected}, change {id}")));
            }
            StateChange::PlacementUpsert(id, placement)
        }
        (WORKSPACE_PLACEMENT, false) => StateChange::PlacementDelete(id),
        _ => StateChange::Other(resource),
    }))
}

/// The groups and placements of a snapshot's `extra.state`. A missing or
/// malformed array (an older daemon) leaves that map empty; a malformed item
/// is skipped and logged.
pub(crate) fn from_extra(
    extra: &BTreeMap<String, Value>,
) -> (BTreeMap<String, WorkspaceGroupSnapshot>, BTreeMap<String, WorkspacePlacementSnapshot>) {
    let state = extra.get("state");
    let items = |key: &str| {
        state
            .and_then(|state| state.get(key))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    };
    let mut groups = BTreeMap::new();
    for item in items("workspace_groups") {
        match serde_json::from_value::<WorkspaceGroupSnapshot>(item) {
            Ok(group) => {
                groups.insert(group.id.clone(), group);
            }
            Err(error) => log::warn!("snapshot workspace group skipped: {error}"),
        }
    }
    let mut placements = BTreeMap::new();
    for item in items("workspace_placements") {
        match serde_json::from_value::<WorkspacePlacementSnapshot>(item) {
            Ok(placement) => {
                placements.insert(placement.workspace.placement_id(), placement);
            }
            Err(error) => log::warn!("snapshot workspace placement skipped: {error}"),
        }
    }
    (groups, placements)
}
