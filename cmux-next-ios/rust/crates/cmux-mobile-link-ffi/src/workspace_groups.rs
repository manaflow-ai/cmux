//! The phone's workspace group rules: where each workspace sits in the Mac's
//! mixed sidebar order with groups, which groups a phone may use, the room a
//! new group goes to, the next group color and names, which groups the list
//! shows, what Collapse Others / Collapse All change, and the ledger of group
//! edits this phone made that a refresh of the Mac's list may not show yet.
//!
//! Leo: "They need to just keep going" (move the iOS app's shared logic into
//! Rust, slice after slice). Both rules are pure functions of their inputs, so
//! Swift (`WorkspaceGroups.swift`) maps its values in and out and keeps no
//! rule of its own. The order is linear in rows plus groups.

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, PoisonError};

/// One of the Mac's workspace groups (`list-personal.groups`, Swift's
/// `MacWorkspaceGroup`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PhoneWorkspaceGroup {
    pub id: String,
    pub name: String,
    /// A palette name or `#RRGGBB`; none for no color.
    pub color: Option<String>,
    pub is_collapsed: bool,
    /// The group's place among the groups.
    pub index: i64,
    /// The personal row the group shows right before; none after every loose workspace.
    pub top_index: Option<i64>,
    /// The room the group belongs to.
    pub room: Option<String>,
    /// A pinned (saved) group; none from an older Mac.
    pub is_pinned: Option<bool>,
}

/// A personal sidebar row (`list-personal.rows`): one workspace of one session.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PhoneSidebarRow {
    pub session: String,
    pub key: String,
    pub index: i64,
    pub group: Option<String>,
}

/// Where one workspace goes: its place in the sidebar order and its group's id.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceGroupSlot {
    pub sidebar_index: i64,
    pub group: Option<String>,
}

/// The Mac's mixed sidebar order with groups (cmux-next
/// `PersonalSidebar.mixedSections`): walk every personal row by place; before
/// row i come the groups whose `top_index` is i (their members in personal
/// order), then row i when it is loose. Workspaces without a row follow, then
/// the groups placed after every row. Returns one slot per `workspace_ids`
/// entry, in its order. Only rows of session `registry_id` are this Mac's;
/// a row whose group the list does not carry is loose.
#[uniffi::export]
pub fn workspace_group_slots(
    rows: Vec<PhoneSidebarRow>,
    groups: Vec<PhoneWorkspaceGroup>,
    workspace_ids: Vec<String>,
    registry_id: String,
) -> Vec<WorkspaceGroupSlot> {
    let mut ordered: Vec<&PhoneSidebarRow> = rows.iter().collect();
    ordered.sort_by_key(|row| row.index);
    let known: HashSet<&str> = groups.iter().map(|g| g.id.as_str()).collect();
    let mine: Vec<&PhoneSidebarRow> =
        ordered.iter().copied().filter(|row| row.session == registry_id).collect();
    let mut group_of: HashMap<&str, &str> = HashMap::new();
    for row in &mine {
        if let Some(group) = row.group.as_deref().filter(|g| known.contains(g)) {
            group_of.entry(row.key.as_str()).or_insert(group);
        }
    }
    // Each group's members in personal order: one pass over the rows.
    let mut members: HashMap<&str, Vec<&str>> = HashMap::new();
    for row in &mine {
        if let Some(group) = group_of.get(row.key.as_str()) {
            members.entry(group).or_default().push(row.key.as_str());
        }
    }
    let mut sorted_groups: Vec<&PhoneWorkspaceGroup> = groups.iter().collect();
    sorted_groups.sort_by_key(|g| g.index);
    // Groups by the row they sit before, in group order; the rest after every row.
    let mut at_row: HashMap<i64, Vec<&str>> = HashMap::new();
    let mut after_rows: Vec<&str> = Vec::new();
    for group in &sorted_groups {
        match group.top_index {
            Some(top) if top >= ordered.len() as i64 => after_rows.push(&group.id),
            Some(top) => at_row.entry(top).or_default().push(&group.id),
            None => after_rows.push(&group.id),
        }
    }
    let members_of = |group: &str| members.get(group).map(Vec::as_slice).unwrap_or(&[]);

    let mut sequence: Vec<&str> = Vec::with_capacity(mine.len() + workspace_ids.len());
    for (index, row) in ordered.iter().enumerate() {
        for group in at_row.get(&(index as i64)).map(Vec::as_slice).unwrap_or(&[]) {
            sequence.extend(members_of(group).iter().copied());
        }
        if row.session == registry_id && !group_of.contains_key(row.key.as_str()) {
            sequence.push(row.key.as_str());
        }
    }
    let rowed: HashSet<&str> = mine.iter().map(|row| row.key.as_str()).collect();
    sequence.extend(workspace_ids.iter().map(String::as_str).filter(|id| !rowed.contains(id)));
    for group in &after_rows {
        sequence.extend(members_of(group).iter().copied());
    }

    let mut position: HashMap<&str, usize> = HashMap::with_capacity(sequence.len());
    for (place, id) in sequence.iter().enumerate() {
        position.entry(id).or_insert(place);
    }
    workspace_ids
        .iter()
        .enumerate()
        .map(|(i, id)| WorkspaceGroupSlot {
            sidebar_index: position.get(id.as_str()).copied().unwrap_or(sequence.len() + i) as i64,
            group: group_of.get(id.as_str()).map(|g| (*g).to_owned()),
        })
        .collect()
}

/// How long an answered edit outlasts refreshes that do not show it (seconds).
pub const GROUP_EDIT_CONFIRM_WINDOW: f64 = 10.0;
/// An edit the Mac never answered gives way after this long (seconds).
pub const GROUP_EDIT_UNANSWERED_WINDOW: f64 = 30.0;

/// A group edit this phone made that the Mac's list may not show yet.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PendingGroupEdit {
    /// The group the workspace shows (none: no group).
    pub group: Option<PhoneWorkspaceGroup>,
    /// False: the edit only marks the latest one (a new group the Mac names
    /// with its own id); refreshes show the Mac's group.
    pub holds: bool,
    /// When its request left for the Mac, in seconds (none: queued behind earlier ones).
    pub sent_at: Option<f64>,
    /// When the Mac accepted it, in seconds.
    pub answered_at: Option<f64>,
}

/// What a refreshed row does with the edit pending on it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum GroupEditStep {
    /// The edit does not hold: the row shows the Mac's group, the edit stays.
    Pass,
    /// The edit is done (shown back, or its window passed): forget it; the row shows the Mac's group.
    Forget,
    /// The row shows this group instead of the Mac's, and the edit stays.
    Hold { group: Option<PhoneWorkspaceGroup> },
}

/// One refreshed row's group (`incoming`, from the Mac) under the edit pending
/// on it, at `now` seconds. An answered edit holds until a refresh shows it or
/// the confirm window passes; an unanswered one until the unanswered window
/// passes from when it was sent. Then the Mac's state wins again (another
/// device may change it).
#[uniffi::export]
pub fn pending_group_edit_step(
    edit: PendingGroupEdit,
    incoming: Option<PhoneWorkspaceGroup>,
    now: f64,
) -> GroupEditStep {
    if !edit.holds {
        return GroupEditStep::Pass;
    }
    let expired = match (edit.answered_at, edit.sent_at) {
        (Some(answered), _) => now - answered > GROUP_EDIT_CONFIRM_WINDOW,
        (None, Some(sent)) => now - sent > GROUP_EDIT_UNANSWERED_WINDOW,
        (None, None) => false,
    };
    if expired || (edit.answered_at.is_some() && group_shows(incoming.as_ref(), edit.group.as_ref())) {
        return GroupEditStep::Forget;
    }
    GroupEditStep::Hold { group: group_merged(incoming, edit.group) }
}

/// The Mac's group carries the edit (its place among groups may differ).
fn group_shows(incoming: Option<&PhoneWorkspaceGroup>, expected: Option<&PhoneWorkspaceGroup>) -> bool {
    match (incoming, expected) {
        (Some(incoming), Some(expected)) => {
            incoming.id == expected.id
                && incoming.name == expected.name
                && incoming.color == expected.color
                && incoming.is_collapsed == expected.is_collapsed
        }
        (None, None) => true,
        _ => false,
    }
}

/// The edit over the Mac's group: the Mac's place, the edit's fields.
fn group_merged(
    incoming: Option<PhoneWorkspaceGroup>,
    expected: Option<PhoneWorkspaceGroup>,
) -> Option<PhoneWorkspaceGroup> {
    let mut expected = expected?;
    match incoming {
        Some(mut incoming) if incoming.id == expected.id => {
            incoming.name = expected.name;
            incoming.color = expected.color;
            incoming.is_collapsed = expected.is_collapsed;
            Some(incoming)
        }
        other => {
            if let Some(incoming) = other {
                expected.index = incoming.index;
            }
            Some(expected)
        }
    }
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

/// The groups whose workspaces are all of session `registry_id` (or that are
/// empty), in the Mac's group order: the groups a phone may change and move
/// this Mac's workspaces into (a Mac group holds one machine's workspaces).
/// Returns indexes of `groups`.
#[uniffi::export]
pub fn workspace_group_own(
    rows: Vec<PhoneSidebarRow>,
    groups: Vec<PhoneWorkspaceGroup>,
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
    pub group: Option<PhoneWorkspaceGroup>,
}

/// A row whose group an edit still holds: its index in the rows given, and the group it shows.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupEditHeld {
    pub index: u32,
    pub group: Option<PhoneWorkspaceGroup>,
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
/// yes until a refresh shows it or `GROUP_EDIT_CONFIRM_WINDOW` passes; then the Mac's
/// state wins again (another device may change it). Only the latest edit of a
/// workspace counts: a refused earlier tap does not undo a later one. Each
/// refreshed row's hold is `pending_group_edit_step`.
#[derive(Debug, Default, uniffi::Object)]
pub struct GroupEditLedger {
    inner: Mutex<Ledger>,
}

#[derive(Debug, Clone)]
struct LedgerEdit {
    edit: PendingGroupEdit,
    generation: u64,
}

#[derive(Debug, Default)]
struct Ledger {
    edits: HashMap<String, LedgerEdit>,
    generation: u64,
}

impl GroupEditLedger {
    fn with<R>(&self, f: impl FnOnce(&mut Ledger) -> R) -> R {
        f(&mut self.inner.lock().unwrap_or_else(PoisonError::into_inner))
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
    pub fn begin(&self, workspace_ids: Vec<String>, group: Option<PhoneWorkspaceGroup>, holds: bool) -> u64 {
        self.with(|l| {
            l.generation += 1;
            let generation = l.generation;
            for id in workspace_ids {
                let edit = PendingGroupEdit { group: group.clone(), holds, sent_at: None, answered_at: None };
                l.edits.insert(id, LedgerEdit { edit, generation });
            }
            generation
        })
    }

    /// The edit's request left for the Mac (after the Mac's earlier group
    /// requests), at `at` seconds: the unanswered window counts from here.
    pub fn sent(&self, workspace_ids: Vec<String>, generation: u64, at: f64) {
        self.with(|l| {
            for id in workspace_ids {
                if let Some(e) = l.edits.get_mut(&id).filter(|e| e.generation == generation) {
                    e.edit.sent_at = Some(at);
                }
            }
        });
    }

    /// The Mac accepted the edit at `at` seconds: refreshes keep it until one
    /// shows it (a non-holding edit is done).
    pub fn answered(&self, workspace_ids: Vec<String>, generation: u64, at: f64) {
        self.with(|l| {
            for id in workspace_ids {
                let Some(e) = l.edits.get_mut(&id).filter(|e| e.generation == generation) else {
                    continue;
                };
                if e.edit.holds {
                    e.edit.answered_at = Some(at);
                } else {
                    l.edits.remove(&id);
                }
            }
        });
    }

    /// Forgets every edit (sign-in); generations keep counting, so a request
    /// from before never matches a later edit.
    pub fn remove_all(&self) {
        self.with(|l| l.edits.clear());
    }

    /// The Mac refused the edit: the workspaces it was still the latest edit
    /// of (those to roll back), in the order given.
    pub fn refused(&self, workspace_ids: Vec<String>, generation: u64) -> Vec<String> {
        self.with(|l| {
            let mut latest = Vec::new();
            for id in workspace_ids {
                if l.edits.get(&id).is_some_and(|e| e.generation == generation) {
                    l.edits.remove(&id);
                    latest.push(id);
                }
            }
            latest
        })
    }

    /// One Mac's refreshed rows at `now` seconds: the rows whose group an edit
    /// still holds, with the group to show. An edit that expired, or that an
    /// answered refresh now shows, is dropped and its row left as the Mac sent it.
    pub fn apply(&self, rows: Vec<GroupEditRow>, now: f64) -> Vec<GroupEditHeld> {
        self.with(|l| {
            if l.edits.is_empty() {
                return Vec::new();
            }
            let mut held = Vec::new();
            for (index, row) in rows.into_iter().enumerate() {
                let Some(e) = l.edits.get(&row.id) else { continue };
                match pending_group_edit_step(e.edit.clone(), row.group, now) {
                    GroupEditStep::Pass => {}
                    GroupEditStep::Forget => {
                        l.edits.remove(&row.id);
                    }
                    GroupEditStep::Hold { group } => held.push(GroupEditHeld { index: index as u32, group }),
                }
            }
            held
        })
    }
}

#[cfg(test)]
#[path = "workspace_groups_tests.rs"]
mod tests;
