//! The phone's workspace group rules: where each workspace sits in the Mac's
//! mixed sidebar order with groups, and whether a group edit this phone made
//! still holds over a refresh of the Mac's list.
//!
//! Leo: "They need to just keep going" (move the iOS app's shared logic into
//! Rust, slice after slice). Both rules are pure functions of their inputs, so
//! Swift (`WorkspaceGroups.swift`) maps its values in and out and keeps no
//! rule of its own. The order is linear in rows plus groups.

use std::collections::{HashMap, HashSet};

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
    let mut sorted_groups: Vec<&PhoneWorkspaceGroup> = groups.iter().collect();
    sorted_groups.sort_by_key(|g| g.index);

    let mut sequence: Vec<&str> = Vec::with_capacity(mine.len() + workspace_ids.len());
    let emit = |group: &PhoneWorkspaceGroup, sequence: &mut Vec<&str>| {
        for row in &mine {
            if group_of.get(row.key.as_str()) == Some(&group.id.as_str()) {
                sequence.push(row.key.as_str());
            }
        }
    };
    for (index, row) in ordered.iter().enumerate() {
        for group in &sorted_groups {
            if group.top_index == Some(index as i64) {
                emit(group, &mut sequence);
            }
        }
        if row.session == registry_id && !group_of.contains_key(row.key.as_str()) {
            sequence.push(row.key.as_str());
        }
    }
    let rowed: HashSet<&str> = mine.iter().map(|row| row.key.as_str()).collect();
    sequence.extend(workspace_ids.iter().map(String::as_str).filter(|id| !rowed.contains(id)));
    for group in &sorted_groups {
        if group.top_index.is_none_or(|top| top >= ordered.len() as i64) {
            emit(group, &mut sequence);
        }
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
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
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

#[cfg(test)]
#[path = "workspace_groups_tests.rs"]
mod tests;
