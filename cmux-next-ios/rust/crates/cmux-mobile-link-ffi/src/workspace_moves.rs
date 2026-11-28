//! The phone's workspace move rules, on workspace ids: the personal index a
//! move asks the Mac for (Move Up / Down, to Top / Bottom, each Sort step),
//! the rows Move Above… / Below… offers and the order it leaves, and the
//! one-row-at-a-time steps of a sort.
//!
//! Leo: "They need to just keep going" (move the iOS app's shared logic into
//! Rust, slice after slice). Swift (`WorkspaceArrangement.swift`) maps its
//! workspaces to ids and back; every rule is here.

use crate::workspace_groups::PhoneSidebarRow;

/// The person's whole order (every session's rows, by place) without
/// `workspace_id` of session `registry_id`: the order a move inserts into.
fn order_without(rows: &[PhoneSidebarRow], registry_id: &str, workspace_id: &str) -> Vec<(String, String)> {
    let mut ordered: Vec<&PhoneSidebarRow> = rows.iter().collect();
    ordered.sort_by_key(|row| row.index);
    ordered
        .into_iter()
        .filter(|row| !(row.session == registry_id && row.key == workspace_id))
        .map(|row| (row.session.clone(), row.key.clone()))
        .collect()
}

fn anchor_place(
    rows: &[PhoneSidebarRow],
    registry_id: &str,
    workspace_id: &str,
    anchor_id: &str,
    after: bool,
) -> Option<i64> {
    let order = order_without(rows, registry_id, workspace_id);
    let at = order.iter().position(|(session, key)| session == registry_id && key == anchor_id)?;
    Some((if after { at + 1 } else { at }) as i64)
}

/// Move Workspace Up (`offset` -1) / Down (+1) among `visible_ids` (the Mac's
/// sidebar order, pinned tiles left out), as the Mac's `movePersonalWorkspace`:
/// the personal index next to its neighbour. None at either end, or when the
/// neighbour has no personal row.
#[uniffi::export]
pub fn personal_index_moving(
    rows: Vec<PhoneSidebarRow>,
    workspace_id: String,
    offset: i64,
    visible_ids: Vec<String>,
    registry_id: String,
) -> Option<i64> {
    let position = visible_ids.iter().position(|id| *id == workspace_id)? as i64;
    let anchor = visible_ids.get(usize::try_from(position + offset).ok()?)?;
    anchor_place(&rows, &registry_id, &workspace_id, anchor, offset > 0)
}

/// The personal index that puts `workspace_id` right before (`after` false) or
/// right after `anchor_id` (Move Workspace to Top / to Bottom, each step of
/// Sort Workspaces). None when either has no personal row.
#[uniffi::export]
pub fn personal_index_placing(
    rows: Vec<PhoneSidebarRow>,
    workspace_id: String,
    anchor_id: String,
    after: bool,
    registry_id: String,
) -> Option<i64> {
    if anchor_id == workspace_id {
        return None;
    }
    anchor_place(&rows, &registry_id, &workspace_id, &anchor_id, after)
}

/// The rows `workspace_id` can go next to (Move Workspace Above…, `above`
/// true, or Below…) in `order` (its container): every other row except the
/// one it already sits right after (above) or right before (below). Empty
/// when it is not in `order`.
#[uniffi::export]
pub fn neighbor_move_targets(above: bool, workspace_id: String, order: Vec<String>) -> Vec<String> {
    let Some(position) = order.iter().position(|id| *id == workspace_id) else {
        return Vec::new();
    };
    order
        .iter()
        .enumerate()
        .filter(|(index, id)| {
            **id != workspace_id
                && if above { *index != position + 1 } else { position.checked_sub(1) != Some(*index) }
        })
        .map(|(_, id)| id.clone())
        .collect()
}

/// `order` once `workspace_id` sits right before (`above`) or after
/// `target_id`; `order` unchanged when the target is not in it.
#[uniffi::export]
pub fn neighbor_move_reordered(
    above: bool,
    workspace_id: String,
    target_id: String,
    order: Vec<String>,
) -> Vec<String> {
    let mut rows: Vec<String> = order.iter().filter(|id| **id != workspace_id).cloned().collect();
    let Some(at) = rows.iter().position(|id| *id == target_id) else {
        return order;
    };
    rows.insert(if above { at } else { at + 1 }, workspace_id);
    rows
}

/// One move of a sort: `workspace` goes right before (`after` false) or after `anchor`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceSortStep {
    pub workspace: String,
    pub anchor: String,
    pub after: bool,
}

/// The moves that turn `order` (one container) into `sorted`, one row at a
/// time as the Mac places them: the first row before the container's current
/// first row, each next one right after the one before it. Rows already in
/// place are not moved.
#[uniffi::export]
pub fn workspace_sort_steps(order: Vec<String>, sorted: Vec<String>) -> Vec<WorkspaceSortStep> {
    let mut current = order;
    let mut steps = Vec::new();
    for (offset, workspace) in sorted.iter().enumerate() {
        let Some(at) = current.iter().position(|id| id == workspace) else { continue };
        if at == offset {
            continue;
        }
        let anchor = if offset == 0 { current[0].clone() } else { sorted[offset - 1].clone() };
        steps.push(WorkspaceSortStep { workspace: workspace.clone(), anchor, after: offset != 0 });
        let moved = current.remove(at);
        current.insert(offset.min(current.len()), moved);
    }
    steps
}

#[cfg(test)]
#[path = "workspace_moves_tests.rs"]
mod tests;
