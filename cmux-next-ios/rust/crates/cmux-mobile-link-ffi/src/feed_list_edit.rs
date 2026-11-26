//! How the phone's Feed list changes from one store update to the next:
//! which chats' runs fold into a stack ("3 earlier updates"), and the
//! inserts, removals and moves that turn the shown row order into the new
//! one so the list animates them instead of rebuilding.
//!
//! These rules were a Swift copy in CmuxMobileFeed's `FeedListPlan.swift`
//! (`FeedStacks`, `FeedSnapshotEdit`, `FeedMoveEdit`). Swift now hands the
//! row ids here and only applies the answer to its UIKit snapshot (Leo,
//! 2026-11-25: "i was wondering why we even have swift at all"; Lawrence,
//! 2026-11-02: "move as much from swift into rust as possible").
//!
//! Each function is linear in the rows given (hash sets, no nested scans).

use std::collections::HashSet;

/// What stacking needs to know of one Feed event.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FeedStackItem {
    pub id: String,
    /// The chat it belongs to: one Mac's workspace and tab.
    pub mac_id: Option<String>,
    pub workspace_id: String,
    pub tab_id: Option<String>,
    /// An ask waiting on the person, an answer on its way, or a refused
    /// answer: never folded and never leads a stack.
    pub keeps_own_row: bool,
}

/// One row of the stacked list.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FeedStackRow {
    /// The event at this index of the input.
    Event { index: u32 },
    /// The fold line under the event at `head` (an index of the input),
    /// standing for `count` older events of its chat.
    Fold { head: u32, count: u32, expanded: bool },
}

/// The Feed's rows with each chat's run folded.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct FeedStacking {
    pub rows: Vec<FeedStackRow>,
    /// The newest event of each stack, in list order.
    pub heads: Vec<String>,
    /// The events folded away, in order.
    pub hidden: Vec<String>,
    /// The stacks open now, by their newest event's id: a stack that got a
    /// newer event stays open under it, and stacks that are gone drop out.
    pub expanded: Vec<String>,
}

fn same_chat(a: &FeedStackItem, b: &FeedStackItem) -> bool {
    a.workspace_id == b.workspace_id && a.tab_id == b.tab_id && a.mac_id == b.mac_id
}

/// When one chat posts several events in a row, with no other chat's event
/// between them, the newest shows as the full row and the older ones fold
/// into one line under it. `open`: rows that never fold (a reply being
/// written under them); one may still lead a stack.
#[uniffi::export]
pub fn feed_stacking(items: Vec<FeedStackItem>, expanded: Vec<String>, open: Vec<String>) -> FeedStacking {
    let mut expanded: HashSet<String> = expanded.into_iter().collect();
    let open: HashSet<String> = open.into_iter().collect();
    let mut out = FeedStacking { rows: Vec::with_capacity(items.len()), ..Default::default() };
    let mut live: Vec<String> = Vec::new();
    let mut index = 0;
    while index < items.len() {
        let head = &items[index];
        let mut end = index + 1;
        if !head.keeps_own_row {
            while end < items.len()
                && same_chat(&items[end], head)
                && !items[end].keeps_own_row
                && !open.contains(&items[end].id)
            {
                end += 1;
            }
        }
        out.rows.push(FeedStackRow::Event { index: index as u32 });
        let older = &items[index + 1..end];
        if !older.is_empty() {
            // The stack was open under an event that is now one of its older ones: it stays open.
            if !expanded.contains(&head.id)
                && let Some(was) = older.iter().find(|o| expanded.contains(&o.id))
            {
                expanded.remove(&was.id);
                expanded.insert(head.id.clone());
            }
            let is_expanded = expanded.contains(&head.id);
            if is_expanded {
                live.push(head.id.clone());
            }
            out.heads.push(head.id.clone());
            out.rows.push(FeedStackRow::Fold {
                head: index as u32,
                count: older.len() as u32,
                expanded: is_expanded,
            });
            if is_expanded {
                out.rows.extend((index + 1..end).map(|i| FeedStackRow::Event { index: i as u32 }));
            } else {
                out.hidden.extend(older.iter().map(|o| o.id.clone()));
            }
        }
        index = end;
    }
    out.expanded = live;
    out
}

/// New rows inserted before a row that was already shown.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FeedInsertGroup {
    pub before: String,
    pub ids: Vec<String>,
}

/// Inserts and removals that turn one row order into another.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FeedInsertEdit {
    pub removed: Vec<String>,
    pub groups: Vec<FeedInsertGroup>,
    /// New rows after the last kept row.
    pub tail: Vec<String>,
}

/// The edit when the rows both orders keep stay in the same order (a live
/// event, a done swipe); none when they do not (a re-sort), so the list
/// rebuilds the section instead.
#[uniffi::export]
pub fn feed_snapshot_edit(old: Vec<String>, new: Vec<String>) -> Option<FeedInsertEdit> {
    let old_set: HashSet<&str> = old.iter().map(String::as_str).collect();
    let new_set: HashSet<&str> = new.iter().map(String::as_str).collect();
    let kept_old = old.iter().filter(|id| new_set.contains(id.as_str()));
    let kept_new = new.iter().filter(|id| old_set.contains(id.as_str()));
    if !kept_old.eq(kept_new) {
        return None;
    }
    let removed = old.iter().filter(|id| !new_set.contains(id.as_str())).cloned().collect();
    let mut groups = Vec::new();
    let mut buffer: Vec<String> = Vec::new();
    for id in &new {
        if old_set.contains(id.as_str()) {
            if !buffer.is_empty() {
                groups.push(FeedInsertGroup { before: id.clone(), ids: std::mem::take(&mut buffer) });
            }
        } else {
            buffer.push(id.clone());
        }
    }
    Some(FeedInsertEdit { removed, groups, tail: buffer })
}

/// One step of a move edit: put `id` before `before` (none: after the last
/// row). `moved`: a shown row moving; else a new row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FeedMoveStep {
    pub id: String,
    pub before: Option<String>,
    pub moved: bool,
}

/// One row order turned into another by moving a few rows.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FeedMovePlan {
    pub removed: Vec<String>,
    /// From the last row to the first: each step's `before` row is already in its place.
    pub steps: Vec<FeedMoveStep>,
}

/// The edit that moves `movers` (an ask that was answered leaves the pinned
/// group for its place in time, one that opened again goes back), with
/// inserts and removals beside them; none when any other row changes place
/// too (a re-sort), or when no mover or more than `limit` move at once.
#[uniffi::export]
pub fn feed_move_edit(
    old: Vec<String>,
    new: Vec<String>,
    movers: Vec<String>,
    limit: u32,
) -> Option<FeedMovePlan> {
    let old_set: HashSet<&str> = old.iter().map(String::as_str).collect();
    let new_set: HashSet<&str> = new.iter().map(String::as_str).collect();
    let moving: HashSet<&str> =
        movers.iter().map(String::as_str).filter(|id| old_set.contains(id) && new_set.contains(id)).collect();
    if moving.is_empty() || moving.len() > limit as usize {
        return None;
    }
    let kept_old = old.iter().filter(|id| new_set.contains(id.as_str()) && !moving.contains(id.as_str()));
    let kept_new = new.iter().filter(|id| old_set.contains(id.as_str()) && !moving.contains(id.as_str()));
    if !kept_old.eq(kept_new) {
        return None;
    }
    let removed = old.iter().filter(|id| !new_set.contains(id.as_str())).cloned().collect();
    let mut steps = Vec::new();
    let mut after: Option<&String> = None;
    for id in new.iter().rev() {
        let moved = moving.contains(id.as_str());
        if moved || !old_set.contains(id.as_str()) {
            steps.push(FeedMoveStep { id: id.clone(), before: after.cloned(), moved });
        }
        after = Some(id);
    }
    Some(FeedMovePlan { removed, steps })
}

/// The steps applied to `old` (what the list does to its snapshot).
#[uniffi::export]
pub fn feed_move_edit_applied(edit: FeedMovePlan, old: Vec<String>) -> Vec<String> {
    let gone: HashSet<&str> = edit.removed.iter().map(String::as_str).collect();
    let mut order: Vec<String> = old.into_iter().filter(|id| !gone.contains(id.as_str())).collect();
    for step in edit.steps {
        if step.moved {
            order.retain(|id| *id != step.id);
        }
        match step.before.and_then(|b| order.iter().position(|id| *id == b)) {
            Some(at) => order.insert(at, step.id),
            None => order.push(step.id),
        }
    }
    order
}

#[cfg(test)]
#[path = "feed_list_edit_tests.rs"]
mod tests;
