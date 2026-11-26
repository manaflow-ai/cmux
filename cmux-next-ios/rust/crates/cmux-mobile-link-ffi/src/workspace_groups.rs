//! The phone's rules for the Mac's workspace groups (Workspaces list):
//! where each workspace sits in the Mac's mixed sidebar order, which groups
//! a phone may use, the room a new group goes to, the next group color and
//! name, which groups the list shows, what Collapse Others / Collapse All
//! change, and how a group edit the phone already shows holds over list
//! refreshes until the Mac carries it.
//!
//! These rules were a Swift copy in CmuxMobileModel's `WorkspaceGroups.swift`
//! (`SidebarArrangement.applyGroups`, `ownGroups`, `room(forWorkspace:)`,
//! `MacWorkspaceGroup.nextColor`, `PendingGroupEdits`, and the creator's
//! `shownGroups` and collapse rules). Swift now hands the state here and only
//! applies the answer to its store and sends the Mac's requests (Leo,
//! 2026-11-25: "i was wondering why we even have swift at all"; Lawrence,
//! 2026-11-02: "move as much from swift into rust as possible").
//!
//! Each function is linear in the rows given (hash maps, no nested scans).

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, PoisonError};

/// One of the Mac's workspace groups (`list-personal.groups[]`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceGroupInfo {
    pub id: String,
    pub name: String,
    /// A palette name or `#RRGGBB`; none for no color.
    pub color: Option<String>,
    pub collapsed: bool,
    /// The group's place among the groups.
    pub index: i64,
    /// The personal row the group shows right before; none: after every loose workspace.
    pub top_index: Option<i64>,
    pub room: Option<String>,
    pub pinned: Option<bool>,
}

/// One personal sidebar row (`list-personal.workspaces[]`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceGroupRow {
    /// The machine's session (registry id) the workspace belongs to.
    pub session: String,
    pub key: String,
    pub index: i64,
    pub group: Option<String>,
}

/// A room (`list-personal.profiles[]`): its order and the sessions it follows.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceGroupRoom {
    pub id: String,
    pub index: i64,
    pub follows: Vec<String>,
}

/// A workspace pinned to one room (`list-personal.pins[]`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceGroupRoomPin {
    pub session: String,
    pub key: String,
    pub room: String,
}

/// Where one workspace sits in the Mac's mixed order, and its group (an index of the groups given).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceGroupPlacement {
    pub sidebar_index: i64,
    pub group: Option<u32>,
}

/// The room every Mac has (`DEFAULT_PROFILE_ID`).
pub const DEFAULT_ROOM: &str = "default";
/// The Mac's name for a group made without one (`SidebarGroup.named`).
pub const NEW_GROUP_NAME: &str = "New Group";
/// The Mac's name shown for a group whose name is blank (`unnamedGroup`).
pub const UNNAMED_GROUP: &str = "Unnamed Group";
/// The Mac's automatic group color order (`GroupColor.automatic`): never blue or grey.
const AUTOMATIC_COLORS: [&str; 7] = ["red", "green", "yellow", "purple", "cyan", "orange", "pink"];

fn sorted_by_index<T>(items: &[T], index: impl Fn(&T) -> i64) -> Vec<usize> {
    let mut order: Vec<usize> = (0..items.len()).collect();
    // A stable sort keeps the Mac's order for equal indexes, as Swift's `sorted` did on these lists.
    order.sort_by_key(|&i| index(&items[i]));
    order
}

/// The Mac's mixed sidebar order with groups (cmux-next
/// `PersonalSidebar.mixedSections`): walk every personal row by place; before
/// row i come the groups whose `top_index` is i (members in personal order),
/// then row i when it is loose. Workspaces without a row follow, then the
/// groups placed after every row. Returns one placement per workspace id, in
/// the order given; a group is an index of `groups`.
#[uniffi::export]
pub fn workspace_group_placements(
    rows: Vec<WorkspaceGroupRow>,
    groups: Vec<WorkspaceGroupInfo>,
    workspace_ids: Vec<String>,
    registry_id: String,
) -> Vec<WorkspaceGroupPlacement> {
    let ordered: Vec<&WorkspaceGroupRow> =
        sorted_by_index(&rows, |r| r.index).into_iter().map(|i| &rows[i]).collect();
    let mut by_id: HashMap<&str, usize> = HashMap::with_capacity(groups.len());
    for (i, group) in groups.iter().enumerate() {
        by_id.entry(group.id.as_str()).or_insert(i);
    }
    let mine: Vec<&WorkspaceGroupRow> =
        ordered.iter().copied().filter(|r| r.session == registry_id).collect();
    let mut group_of: HashMap<&str, usize> = HashMap::new();
    for row in &mine {
        if let Some(&g) = row.group.as_deref().and_then(|id| by_id.get(id)) {
            group_of.entry(row.key.as_str()).or_insert(g);
        }
    }
    // Each group's members in personal order, keyed by the group's first index in `groups`.
    let mut members: HashMap<usize, Vec<&str>> = HashMap::new();
    for row in &mine {
        if let Some(&g) = group_of.get(row.key.as_str()) {
            members.entry(g).or_default().push(row.key.as_str());
        }
    }
    let sorted_groups = sorted_by_index(&groups, |g| g.index);
    // Groups by the row they show before; a group whose id repeats emits under its first copy's members.
    let mut at_row: HashMap<i64, Vec<usize>> = HashMap::new();
    let mut after_rows: Vec<usize> = Vec::new();
    for &g in &sorted_groups {
        match groups[g].top_index {
            Some(top) if top >= 0 && (top as usize) < ordered.len() => at_row.entry(top).or_default().push(g),
            Some(top) if top < 0 => {}
            _ => after_rows.push(g),
        }
    }
    let emit = |sequence: &mut Vec<&str>, g: usize| {
        let first = by_id.get(groups[g].id.as_str()).copied().unwrap_or(g);
        if let Some(keys) = members.get(&first) {
            sequence.extend(keys.iter().copied());
        }
    };
    let mut sequence: Vec<&str> = Vec::with_capacity(workspace_ids.len());
    for (index, row) in ordered.iter().enumerate() {
        for &g in at_row.get(&(index as i64)).map(Vec::as_slice).unwrap_or(&[]) {
            emit(&mut sequence, g);
        }
        if row.session == registry_id && !group_of.contains_key(row.key.as_str()) {
            sequence.push(row.key.as_str());
        }
    }
    let rowed: HashSet<&str> = mine.iter().map(|r| r.key.as_str()).collect();
    sequence.extend(workspace_ids.iter().map(String::as_str).filter(|id| !rowed.contains(id)));
    for &g in &after_rows {
        emit(&mut sequence, g);
    }
    let mut position: HashMap<&str, usize> = HashMap::with_capacity(sequence.len());
    for (i, id) in sequence.iter().enumerate() {
        position.entry(id).or_insert(i);
    }
    workspace_ids
        .iter()
        .enumerate()
        .map(|(i, id)| WorkspaceGroupPlacement {
            sidebar_index: position.get(id.as_str()).copied().unwrap_or(sequence.len() + i) as i64,
            group: group_of.get(id.as_str()).map(|&g| g as u32),
        })
        .collect()
}

/// The groups whose workspaces are all of session `registry_id` (or that are
/// empty), in the Mac's group order: the groups a phone may change and move
/// this Mac's workspaces into (a Mac group holds one machine's workspaces).
/// Returns indexes of `groups`.
#[uniffi::export]
pub fn workspace_group_own(
    rows: Vec<WorkspaceGroupRow>,
    groups: Vec<WorkspaceGroupInfo>,
    registry_id: String,
) -> Vec<u32> {
    let others: HashSet<&str> =
        rows.iter().filter(|r| r.session != registry_id).filter_map(|r| r.group.as_deref()).collect();
    sorted_by_index(&groups, |g| g.index)
        .into_iter()
        .filter(|&i| !others.contains(groups[i].id.as_str()))
        .map(|i| i as u32)
        .collect()
}

/// The room a new group for workspace `key` goes to, as the Mac's window that
/// shows it: the room it is pinned to, else the first room (in room order)
/// that follows this session, else the default room.
#[uniffi::export]
pub fn workspace_group_room(
    rooms: Vec<WorkspaceGroupRoom>,
    pins: Vec<WorkspaceGroupRoomPin>,
    key: String,
    registry_id: String,
) -> String {
    if let Some(pin) = pins.into_iter().find(|p| p.session == registry_id && p.key == key) {
        return pin.room;
    }
    sorted_by_index(&rooms, |r| r.index)
        .into_iter()
        .find(|&i| rooms[i].follows.contains(&registry_id))
        .map(|i| rooms[i].id.clone())
        .unwrap_or_else(|| DEFAULT_ROOM.to_string())
}

/// The Mac's next group color (`GroupColor.automatic`): the first of its
/// automatic order no group uses, never blue or grey; grey when all are used.
#[uniffi::export]
pub fn workspace_group_next_color(used: Vec<String>) -> String {
    let used: HashSet<&str> = used.iter().map(String::as_str).collect();
    AUTOMATIC_COLORS.iter().find(|c| !used.contains(*c)).copied().unwrap_or("grey").to_string()
}

/// Move Workspace to New Group's name: what was typed, trimmed; "New Group" when blank.
#[uniffi::export]
pub fn workspace_group_new_name(typed: String) -> String {
    let trimmed = typed.trim();
    if trimmed.is_empty() { NEW_GROUP_NAME.to_string() } else { trimmed.to_string() }
}

/// Rename Group…'s new name: what was typed, trimmed; none when blank or the same name (nothing to send).
#[uniffi::export]
pub fn workspace_group_rename(current: String, typed: String) -> Option<String> {
    let trimmed = typed.trim();
    (!trimmed.is_empty() && trimmed != current).then(|| trimmed.to_string())
}

/// The name the list shows: the name, else "Unnamed Group" (the Mac's `unnamedGroup`).
#[uniffi::export]
pub fn workspace_group_display_name(name: String) -> String {
    // Foundation's `.whitespaces`: blanks only, a line break is a name.
    let blank = name.chars().all(|c| {
        c.is_whitespace()
            && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    });
    if blank { UNNAMED_GROUP.to_string() } else { name }
}

/// One of a Mac's rows on the phone, for which groups the list shows.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceGroupShownRow {
    pub sidebar_index: Option<i64>,
    pub group: Option<String>,
}

/// The groups one Mac's rows show, in the order their first rows show:
/// indexes of `rows`, one per group (its first row).
#[uniffi::export]
pub fn workspace_group_shown(rows: Vec<WorkspaceGroupShownRow>) -> Vec<u32> {
    let mut order: Vec<usize> = (0..rows.len()).collect();
    order.sort_by_key(|&i| (rows[i].sidebar_index.unwrap_or(i64::MAX), i));
    let mut seen: HashSet<&str> = HashSet::new();
    order
        .into_iter()
        .filter(|&i| rows[i].group.as_deref().is_some_and(|g| seen.insert(g)))
        .map(|i| i as u32)
        .collect()
}

/// A shown group's fold.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceGroupFold {
    pub id: String,
    pub collapsed: bool,
}

/// Collapse Other Groups (`keeping`: that group opens, every other folds, the
/// Mac's `groupsToggledByCollapsingOthers`), or Collapse All / Expand All
/// (`keeping` none: every group to `collapsed`). Returns the folds that
/// change, in the order given; empty: the menu item would do nothing.
#[uniffi::export]
pub fn workspace_group_fold_changes(
    shown: Vec<WorkspaceGroupFold>,
    keeping: Option<String>,
    collapsed: bool,
) -> Vec<WorkspaceGroupFold> {
    shown
        .into_iter()
        .filter_map(|fold| {
            let want = match &keeping {
                Some(keep) => fold.id != *keep,
                None => collapsed,
            };
            (fold.collapsed != want).then_some(WorkspaceGroupFold { id: fold.id, collapsed: want })
        })
        .collect()
}

/// One workspace row of a refresh, for the edits it does not show yet.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupEditRow {
    pub id: String,
    pub group: Option<WorkspaceGroupInfo>,
}

/// A row whose group an edit still holds: its index in the rows given, and the group it shows.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupEditHeld {
    pub index: u32,
    pub group: Option<WorkspaceGroupInfo>,
}

#[derive(Debug, Clone)]
struct PendingEdit {
    group: Option<WorkspaceGroupInfo>,
    generation: u64,
    /// When its request left for the Mac (none: queued behind earlier ones).
    sent_at_ms: Option<i64>,
    answered_at_ms: Option<i64>,
    /// False: the edit only marks the latest one (a new group, which the Mac
    /// names with its own id); refreshes show the Mac's group.
    holds: bool,
}

#[derive(Debug, Default)]
struct Ledger {
    edits: HashMap<String, PendingEdit>,
    generation: u64,
}

/// Group edits this phone made that the Mac's list has not shown back yet.
///
/// The phone shows a group change at once and sends it to the Mac. Until the
/// Mac's list carries it, a tree refresh (a terminal title, an agent event, a
/// notification) can publish the group as it was: the list's arrangement is
/// cached and only re-read after the Mac answers. Without this a collapsed
/// group opened again by itself, and a second tap seemed to be needed
/// ("disclosure groups not being properly closable"). An edit holds its
/// members' group over refreshes while it is in flight, and after the Mac's
/// yes until a refresh shows it or `CONFIRM_WINDOW_MS` passes; then the Mac's
/// state wins again (another device may change it). Only the latest edit of a
/// workspace counts: a refused earlier tap does not undo a later one.
#[derive(Debug, Default, uniffi::Object)]
pub struct GroupEditLedger {
    inner: Mutex<Ledger>,
}

/// How long an answered edit outlasts refreshes that do not show it.
pub const CONFIRM_WINDOW_MS: i64 = 10_000;
/// An edit the Mac never answered gives way after this long.
pub const UNANSWERED_WINDOW_MS: i64 = 30_000;

impl GroupEditLedger {
    fn with<R>(&self, f: impl FnOnce(&mut Ledger) -> R) -> R {
        f(&mut self.inner.lock().unwrap_or_else(PoisonError::into_inner))
    }
}

/// The Mac's group carries the edit (its place among groups may differ).
pub fn group_shows(incoming: Option<&WorkspaceGroupInfo>, expected: Option<&WorkspaceGroupInfo>) -> bool {
    match (incoming, expected) {
        (Some(i), Some(e)) => {
            i.id == e.id && i.name == e.name && i.color == e.color && i.collapsed == e.collapsed
        }
        (None, None) => true,
        _ => false,
    }
}

/// The edit over the Mac's group: the Mac's place, the edit's fields.
pub fn group_merged(
    incoming: Option<&WorkspaceGroupInfo>,
    expected: Option<&WorkspaceGroupInfo>,
) -> Option<WorkspaceGroupInfo> {
    let mut expected = expected?.clone();
    match incoming {
        Some(incoming) if incoming.id == expected.id => {
            let mut merged = incoming.clone();
            merged.name = expected.name;
            merged.color = expected.color;
            merged.collapsed = expected.collapsed;
            Some(merged)
        }
        other => {
            if let Some(incoming) = other {
                expected.index = incoming.index;
            }
            Some(expected)
        }
    }
}

#[uniffi::export]
impl GroupEditLedger {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.with(|l| l.edits.is_empty())
    }

    /// The workspaces now show `group` (none: no group); returns the edit's
    /// generation. It replaces any earlier edit of those workspaces.
    pub fn begin(&self, workspace_ids: Vec<String>, group: Option<WorkspaceGroupInfo>, holds: bool) -> u64 {
        self.with(|l| {
            l.generation += 1;
            let generation = l.generation;
            for id in workspace_ids {
                l.edits.insert(
                    id,
                    PendingEdit {
                        group: group.clone(),
                        generation,
                        sent_at_ms: None,
                        answered_at_ms: None,
                        holds,
                    },
                );
            }
            generation
        })
    }

    /// The edit's request left for the Mac (after the Mac's earlier group
    /// requests): the unanswered window counts from here.
    pub fn sent(&self, workspace_ids: Vec<String>, generation: u64, at_ms: i64) {
        self.with(|l| {
            for id in workspace_ids {
                if let Some(edit) = l.edits.get_mut(&id).filter(|e| e.generation == generation) {
                    edit.sent_at_ms = Some(at_ms);
                }
            }
        })
    }

    /// The Mac accepted the edit: refreshes keep it until one shows it (a
    /// non-holding edit is done).
    pub fn answered(&self, workspace_ids: Vec<String>, generation: u64, at_ms: i64) {
        self.with(|l| {
            for id in workspace_ids {
                let Some(edit) = l.edits.get_mut(&id).filter(|e| e.generation == generation) else {
                    continue;
                };
                if edit.holds {
                    edit.answered_at_ms = Some(at_ms);
                } else {
                    l.edits.remove(&id);
                }
            }
        })
    }

    /// Forgets every edit (sign-in); generations keep counting, so a request
    /// from before never matches a later edit.
    pub fn remove_all(&self) {
        self.with(|l| l.edits.clear())
    }

    /// The Mac refused the edit: the workspaces it was still the latest edit
    /// of (those to roll back), in the order given.
    pub fn refused(&self, workspace_ids: Vec<String>, generation: u64) -> Vec<String> {
        self.with(|l| {
            let mut latest = Vec::new();
            for id in workspace_ids {
                if l.edits.get(&id).is_some_and(|e| e.generation == generation) {
                    l.edits.remove(&id);
                    if !latest.contains(&id) {
                        latest.push(id);
                    }
                }
            }
            latest
        })
    }

    /// One Mac's refreshed rows: the rows whose group an edit still holds,
    /// with the group to show. An edit that expired, or that an answered
    /// refresh now shows, is dropped and its row left as the Mac sent it.
    pub fn apply(&self, rows: Vec<GroupEditRow>, now_ms: i64) -> Vec<GroupEditHeld> {
        self.with(|l| {
            if l.edits.is_empty() {
                return Vec::new();
            }
            let mut held = Vec::new();
            for (index, row) in rows.into_iter().enumerate() {
                let Some(edit) = l.edits.get(&row.id) else { continue };
                if !edit.holds {
                    continue;
                }
                let expired = match (edit.answered_at_ms, edit.sent_at_ms) {
                    (Some(answered), _) => now_ms - answered > CONFIRM_WINDOW_MS,
                    (None, Some(sent)) => now_ms - sent > UNANSWERED_WINDOW_MS,
                    (None, None) => false,
                };
                if expired
                    || (edit.answered_at_ms.is_some() && group_shows(row.group.as_ref(), edit.group.as_ref()))
                {
                    l.edits.remove(&row.id);
                    continue;
                }
                held.push(GroupEditHeld {
                    index: index as u32,
                    group: group_merged(row.group.as_ref(), edit.group.as_ref()),
                });
            }
            held
        })
    }
}

#[cfg(test)]
#[path = "workspace_groups_tests.rs"]
mod tests;
