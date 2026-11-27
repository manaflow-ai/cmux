//! The phone's workspace arrangement rules: where each workspace sits in the
//! linked Mac's sidebar (its pinned tiles and the person's own order; the
//! group order is `workspace_groups::workspace_group_slots`), and the row
//! menu's Move to Top / Bottom, Sort Workspaces (the sort keys and Finder
//! name order), Close Workspaces and the containers a sort runs in. The move
//! indices, Move Above / Below and the sort's steps are `workspace_moves`.
//!
//! These rules were a Swift copy in CmuxMobileModel's
//! `WorkspaceArrangement.swift` (`SidebarArrangement.apply`, `WorkspaceEdge`,
//! `WorkspaceSortKey.sorted`, `WorkspaceBulkClose`,
//! `WorkspaceCreator.containers`). Swift now hands the rows here and only
//! applies the answer to its `Workspace` values (Leo, 2026-11-25: "They need
//! to just keep going"; Lawrence, 2026-11-02: "move as much from swift into
//! rust as possible").
//!
//! Rows go in by id; answers come back as ids or as indices of the input.
//! Each function is linear or n log n in the rows given (hash maps, no
//! nested scans).

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use crate::workspace_groups::{PhoneSidebarRow, PhoneWorkspaceGroup, workspace_group_slots};

/// One pinned tile: its layout item id and its ref value (`<session>:<ws_…>`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArrangementPin {
    pub item_id: String,
    pub value: String,
}

/// One workspace of the daemon's tree, in the daemon's order.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArrangementWorkspace {
    pub id: String,
    pub resource_id: Option<String>,
}

/// What the Mac's sidebar knows beyond its tree. `rows` none: the Mac has no
/// personal order. `pins` none: the Mac has no sidebar layout (the legacy pin
/// flag counts).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArrangementInput {
    pub workspaces: Vec<ArrangementWorkspace>,
    pub registry_id: Option<String>,
    /// The ids the daemon flags pinned.
    pub legacy_pinned: Vec<String>,
    pub rows: Option<Vec<PhoneSidebarRow>>,
    pub pins: Option<Vec<ArrangementPin>>,
    pub groups: Vec<PhoneWorkspaceGroup>,
}

/// Where one workspace (same index as the input) sits.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArrangementPlace {
    pub is_pinned: bool,
    pub pin_index: Option<i64>,
    pub pin_item_id: Option<String>,
    pub sidebar_index: i64,
    /// The id of its group (one of the input's groups), if any.
    pub group: Option<String>,
}

fn ref_value(registry_id: &str, resource_id: &str) -> String {
    format!("{registry_id}:{resource_id}")
}

fn sorted_rows(rows: &[PhoneSidebarRow]) -> Vec<&PhoneSidebarRow> {
    let mut ordered: Vec<&PhoneSidebarRow> = rows.iter().collect();
    // Stable, as Swift's sort of the same rows.
    ordered.sort_by_key(|row| row.index);
    ordered
}

/// Each workspace's pin and sidebar place. Rowed workspaces sit by personal
/// place, the rest after them in daemon order (the Mac's `order`); pins are
/// the tiles of this session's workspaces, in tile order, and a flagged
/// workspace the Mac has not turned into its tile yet shows pinned too. With
/// groups, the place is the Mac's mixed order (`applyGroups` below).
#[uniffi::export]
pub fn workspace_arrangement_apply(input: ArrangementInput) -> Vec<ArrangementPlace> {
    let ArrangementInput { workspaces, registry_id, legacy_pinned, rows, pins, groups } = input;
    let legacy: HashSet<&str> = legacy_pinned.iter().map(String::as_str).collect();
    let mut pin_index: HashMap<&str, (i64, &str)> = HashMap::new();
    for (offset, pin) in pins.iter().flatten().enumerate() {
        pin_index.entry(pin.value.as_str()).or_insert((offset as i64, pin.item_id.as_str()));
    }
    let ordered = rows.as_deref().map(sorted_rows).unwrap_or_default();
    let mut place: HashMap<&str, i64> = HashMap::new();
    for (offset, row) in ordered.iter().enumerate() {
        if registry_id.as_deref() == Some(row.session.as_str()) {
            place.entry(row.key.as_str()).or_insert(offset as i64);
        }
    }
    let row_count = ordered.len() as i64;
    let mut out: Vec<ArrangementPlace> = workspaces
        .iter()
        .enumerate()
        .map(|(i, ws)| {
            let i = i as i64;
            let flagged = legacy.contains(ws.id.as_str());
            let (is_pinned, pin_index, pin_item_id) = match &pins {
                Some(pins) => {
                    let reference = registry_id
                        .as_deref()
                        .zip(ws.resource_id.as_deref())
                        .map(|(registry, resource)| ref_value(registry, resource));
                    let pin = reference.and_then(|r| pin_index.get(r.as_str()).copied());
                    let index = pin.map(|p| p.0).or(flagged.then_some(pins.len() as i64 + i));
                    (pin.is_some() || flagged, index, pin.map(|p| p.1.to_owned()))
                }
                None => (flagged, flagged.then_some(i), None),
            };
            let sidebar_index =
                if rows.is_none() { i } else { place.get(ws.id.as_str()).copied().unwrap_or(row_count + i) };
            ArrangementPlace { is_pinned, pin_index, pin_item_id, sidebar_index, group: None }
        })
        .collect();
    if let (Some(registry), Some(rows)) = (registry_id, rows)
        && !groups.is_empty()
    {
        let ids = workspaces.into_iter().map(|w| w.id).collect();
        for (place, slot) in out.iter_mut().zip(workspace_group_slots(rows, groups, ids, registry)) {
            place.sidebar_index = slot.sidebar_index;
            place.group = slot.group;
        }
    }
    out
}

/// Move Workspace to Top / to Bottom of its container.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WorkspaceEdgeSide {
    Top,
    Bottom,
}

/// The row a move goes next to, and on which side.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceAnchor {
    pub anchor: String,
    pub after: bool,
}

/// The row `workspace` goes next to in `order` (its container, in the Mac's
/// order) for Move to Top / to Bottom; none when it is already there or not
/// in the container.
#[uniffi::export]
pub fn workspace_edge_anchor(
    edge: WorkspaceEdgeSide,
    workspace: String,
    order: Vec<String>,
) -> Option<WorkspaceAnchor> {
    if !order.contains(&workspace) {
        return None;
    }
    let (row, after) = match edge {
        WorkspaceEdgeSide::Top => (order.first()?, false),
        WorkspaceEdgeSide::Bottom => (order.last()?, true),
    };
    (*row != workspace).then(|| WorkspaceAnchor { anchor: row.clone(), after })
}

/// Sort Workspaces by Name / Last Used / Directory (the Mac's `WorkspaceSortKey`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WorkspaceSortBy {
    Name,
    LastUsed,
    Directory,
}

/// What sorting needs to know of one row.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WorkspaceSortRow {
    pub id: String,
    pub title: String,
    /// Empty: none.
    pub directory: String,
    /// Seconds since 1970 of its last activity; none when the phone has no time for it.
    pub last_activity_at: Option<f64>,
    /// The daemon's focus order (higher: focused more recently).
    pub focus_order: i64,
}

/// Finder order: case-insensitive, digit runs compare by value ("b2" before
/// "b10"); names equal but for case compare equal (their place breaks the tie).
fn finder_order(left: &str, right: &str) -> Ordering {
    let mut l = left.chars().peekable();
    let mut r = right.chars().peekable();
    loop {
        match (l.peek().copied(), r.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(a), Some(b)) if a.is_ascii_digit() && b.is_ascii_digit() => {
                let left_run = digits(&mut l);
                let right_run = digits(&mut r);
                let (lv, rv) = (left_run.trim_start_matches('0'), right_run.trim_start_matches('0'));
                let order = lv.len().cmp(&rv.len()).then_with(|| lv.cmp(rv));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(a), Some(b)) => {
                let order = a.to_lowercase().cmp(b.to_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
                l.next();
                r.next();
            }
        }
    }
}

fn digits(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) -> String {
    let mut run = String::new();
    while let Some(c) = chars.peek().copied().filter(char::is_ascii_digit) {
        run.push(c);
        chars.next();
    }
    run
}

/// `rows` (one container, in its current order) sorted by `key`, as the Mac
/// sorts, given as indices of `rows`: `Name` in Finder order; `Directory` by
/// folder, then name, rows without one last; `LastUsed` most recent first
/// (rows without a time last), then the daemon's focus order. Ties keep their
/// current order.
#[uniffi::export]
pub fn workspace_sorted(key: WorkspaceSortBy, rows: Vec<WorkspaceSortRow>) -> Vec<u32> {
    let mut order: Vec<usize> = (0..rows.len()).collect();
    let by_name = |a: &WorkspaceSortRow, b: &WorkspaceSortRow| finder_order(&a.title, &b.title);
    order.sort_by(|&i, &j| {
        let (a, b) = (&rows[i], &rows[j]);
        let primary = match key {
            WorkspaceSortBy::Name => by_name(a, b),
            WorkspaceSortBy::Directory => match (a.directory.is_empty(), b.directory.is_empty()) {
                (false, false) if a.directory != b.directory => finder_order(&a.directory, &b.directory),
                (false, true) => Ordering::Less,
                (true, false) => Ordering::Greater,
                _ => by_name(a, b),
            },
            WorkspaceSortBy::LastUsed => match (a.last_activity_at, b.last_activity_at) {
                (Some(_), None) => Ordering::Less,
                (None, Some(_)) => Ordering::Greater,
                (Some(x), Some(y)) if x != y => y.total_cmp(&x),
                _ => b.focus_order.cmp(&a.focus_order),
            },
        };
        primary.then(i.cmp(&j))
    });
    order.into_iter().map(|i| i as u32).collect()
}

/// Close Other Workspaces / Above / Below / Other Workspaces in Group / All.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WorkspaceCloseKind {
    Others,
    Above,
    Below,
    OthersInGroup,
    All,
}

/// What a bulk close needs to know of one row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceCloseRow {
    pub id: String,
    pub group: Option<String>,
    pub is_home: bool,
}

/// The rows (indices of `order`) a bulk close chosen on `workspace` closes.
/// Home never closes (the Mac's `HomeRules`).
#[uniffi::export]
pub fn workspace_close_targets(
    kind: WorkspaceCloseKind,
    workspace: String,
    order: Vec<WorkspaceCloseRow>,
) -> Vec<u32> {
    let Some(index) = order.iter().position(|row| row.id == workspace) else { return Vec::new() };
    let group = order[index].group.as_deref();
    order
        .iter()
        .enumerate()
        .filter(|(i, row)| match kind {
            WorkspaceCloseKind::Others => row.id != workspace,
            WorkspaceCloseKind::Above => *i < index,
            WorkspaceCloseKind::Below => *i > index,
            WorkspaceCloseKind::OthersInGroup => {
                group.is_some() && row.id != workspace && row.group.as_deref() == group
            }
            WorkspaceCloseKind::All => true,
        })
        .filter(|(_, row)| !row.is_home)
        .map(|(i, _)| i as u32)
        .collect()
}

/// "Close 3 workspaces?" (the phone asks first; the Mac closes at once).
#[uniffi::export]
pub fn workspace_close_question(count: u32) -> String {
    if count == 1 { "Close 1 workspace?".to_owned() } else { format!("Close {count} workspaces?") }
}

/// What splitting a Mac's rows into containers needs to know of one row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceContainerRow {
    pub group: Option<String>,
    pub sidebar_index: Option<i64>,
}

/// The containers of one Mac's sidebar (the loose rows, then each group's
/// members in the order their first rows show), each in the Mac's order
/// (sidebar place, rows without one last, ties in input order), as indices of
/// `rows`. The caller leaves out rows a phone may not arrange.
#[uniffi::export]
pub fn workspace_containers(rows: Vec<WorkspaceContainerRow>) -> Vec<Vec<u32>> {
    let mut order: Vec<usize> = (0..rows.len()).collect();
    order.sort_by_key(|&i| (rows[i].sidebar_index.unwrap_or(i64::MAX), i));
    let mut loose: Vec<u32> = Vec::new();
    let mut groups: Vec<(&str, Vec<u32>)> = Vec::new();
    let mut slot: HashMap<&str, usize> = HashMap::new();
    for i in order {
        match rows[i].group.as_deref() {
            None => loose.push(i as u32),
            Some(group) => {
                let at = *slot.entry(group).or_insert_with(|| {
                    groups.push((group, Vec::new()));
                    groups.len() - 1
                });
                groups[at].1.push(i as u32);
            }
        }
    }
    let mut out = Vec::with_capacity(groups.len() + 1);
    if !loose.is_empty() {
        out.push(loose);
    }
    out.extend(groups.into_iter().map(|(_, members)| members));
    out
}

#[cfg(test)]
#[path = "workspace_arrangement_tests.rs"]
mod tests;
