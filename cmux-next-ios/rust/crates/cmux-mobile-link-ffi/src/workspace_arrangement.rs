//! The phone's workspace arrangement rules: where each workspace sits in the
//! linked Mac's sidebar (its pinned tiles, the person's own order, its
//! groups), the personal index a move sends the Mac, and the row menu's
//! Move to Top / Bottom, Move Above / Below, Sort Workspaces and Close
//! Workspaces rules.
//!
//! These rules were a Swift copy in CmuxMobileModel's
//! `WorkspaceArrangement.swift` and `WorkspaceGroups.swift`
//! (`SidebarArrangement.apply`, `applyGroups`, `personalIndex`,
//! `WorkspaceEdge`, `WorkspaceNeighborMove`, `WorkspaceSortKey`,
//! `WorkspaceBulkClose`, `WorkspaceCreator.containers`). Swift now hands the
//! rows here and only applies the answer to its `Workspace` values (Leo,
//! 2026-11-25: "i was wondering why we even have swift at all"; Lawrence,
//! 2026-11-02: "move as much from swift into rust as possible").
//!
//! Rows go in by id; answers come back as ids or as indices of the input.
//! Each function is linear or n log n in the rows given (hash maps, no
//! nested scans).

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

/// One personal sidebar row of the Mac (`list-personal.workspaces[]`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArrangementPersonalRow {
    pub session: String,
    pub key: String,
    pub index: i64,
    /// Its personal group, if any.
    pub group: Option<String>,
}

/// One pinned tile: its layout item id and its ref value (`<session>:<ws_…>`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArrangementPin {
    pub item_id: String,
    pub value: String,
}

/// One of the person's workspace groups (`list-personal.groups[]`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArrangementGroup {
    pub id: String,
    /// The group's place among the groups.
    pub index: i64,
    /// The personal row the group shows right before; none after every loose row.
    pub top_index: Option<i64>,
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
    pub rows: Option<Vec<ArrangementPersonalRow>>,
    pub pins: Option<Vec<ArrangementPin>>,
    pub groups: Vec<ArrangementGroup>,
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

fn sorted_rows(rows: &[ArrangementPersonalRow]) -> Vec<&ArrangementPersonalRow> {
    let mut ordered: Vec<&ArrangementPersonalRow> = rows.iter().collect();
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
    if let Some(registry) = registry_id.as_deref()
        && rows.is_some()
        && !groups.is_empty()
    {
        apply_groups(&mut out, &workspaces, &ordered, &groups, registry);
    }
    out
}

/// The Mac's mixed sidebar order with groups (cmux-next
/// `PersonalSidebar.mixedSections`): walk every personal row by place; before
/// row i come the groups whose `top_index` is i (members in personal order),
/// then row i when it is loose. Workspaces without a row follow, then the
/// groups placed after every row.
fn apply_groups(
    out: &mut [ArrangementPlace],
    workspaces: &[ArrangementWorkspace],
    ordered: &[&ArrangementPersonalRow],
    groups: &[ArrangementGroup],
    registry: &str,
) {
    let known: HashSet<&str> = groups.iter().map(|g| g.id.as_str()).collect();
    let mine: Vec<&ArrangementPersonalRow> = ordered.iter().copied().filter(|r| r.session == registry).collect();
    let mut group_of: HashMap<&str, &str> = HashMap::new();
    for row in &mine {
        if let Some(group) = row.group.as_deref().filter(|g| known.contains(g)) {
            group_of.entry(row.key.as_str()).or_insert(group);
        }
    }
    let mut members: HashMap<&str, Vec<&str>> = HashMap::new();
    for row in &mine {
        if let Some(group) = group_of.get(row.key.as_str()) {
            members.entry(group).or_default().push(row.key.as_str());
        }
    }
    let mut sorted_groups: Vec<&ArrangementGroup> = groups.iter().collect();
    sorted_groups.sort_by_key(|g| g.index);
    let mut by_top: HashMap<i64, Vec<&str>> = HashMap::new();
    for group in &sorted_groups {
        if let Some(top) = group.top_index {
            by_top.entry(top).or_default().push(group.id.as_str());
        }
    }
    let mut sequence: Vec<&str> = Vec::new();
    for (index, row) in ordered.iter().enumerate() {
        for group in by_top.get(&(index as i64)).into_iter().flatten() {
            sequence.extend(members.get(group).into_iter().flatten());
        }
        if row.session == registry && !group_of.contains_key(row.key.as_str()) {
            sequence.push(row.key.as_str());
        }
    }
    let rowed: HashSet<&str> = mine.iter().map(|r| r.key.as_str()).collect();
    sequence.extend(workspaces.iter().map(|w| w.id.as_str()).filter(|id| !rowed.contains(id)));
    let row_count = ordered.len() as i64;
    for group in &sorted_groups {
        if group.top_index.is_none_or(|top| top >= row_count) {
            sequence.extend(members.get(group.id.as_str()).into_iter().flatten());
        }
    }
    let mut position: HashMap<&str, i64> = HashMap::new();
    for (offset, id) in sequence.iter().enumerate() {
        position.entry(id).or_insert(offset as i64);
    }
    let count = sequence.len() as i64;
    for (i, (place, ws)) in out.iter_mut().zip(workspaces).enumerate() {
        place.sidebar_index = position.get(ws.id.as_str()).copied().unwrap_or(count + i as i64);
        place.group = group_of.get(ws.id.as_str()).map(|g| (*g).to_owned());
    }
}

fn personal_order(rows: &[ArrangementPersonalRow], registry: &str, without: &str) -> Vec<String> {
    sorted_rows(rows)
        .into_iter()
        .filter(|row| !(row.session == registry && row.key == without))
        .map(|row| format!("{}/{}", row.session, row.key))
        .collect()
}

/// Where Move Up (-1) / Down (+1) puts `workspace` among `visible` (the Mac's
/// sidebar order, pinned tiles left out), as the Mac's
/// `movePersonalWorkspace`: the personal index next to its neighbour. None at
/// either end, or when the neighbour has no personal row.
#[uniffi::export]
pub fn workspace_personal_index_moving(
    rows: Vec<ArrangementPersonalRow>,
    registry_id: String,
    workspace: String,
    offset: i64,
    visible: Vec<String>,
) -> Option<i64> {
    let position = visible.iter().position(|id| *id == workspace)? as i64;
    let target = usize::try_from(position + offset).ok()?;
    let anchor = visible.get(target)?;
    let order = personal_order(&rows, &registry_id, &workspace);
    let anchor_key = format!("{registry_id}/{anchor}");
    let anchor_index = order.iter().position(|key| *key == anchor_key)? as i64;
    Some(if offset > 0 { anchor_index + 1 } else { anchor_index })
}

/// The personal index that puts `workspace` right before (`after` false) or
/// right after `anchor` (Move to Top / to Bottom, each step of Sort): the
/// anchor's place in the person's order without the workspace. None when the
/// anchor has no personal row, or is the workspace itself.
#[uniffi::export]
pub fn workspace_personal_index_placing(
    rows: Vec<ArrangementPersonalRow>,
    registry_id: String,
    workspace: String,
    anchor: String,
    after: bool,
) -> Option<i64> {
    if anchor == workspace {
        return None;
    }
    let order = personal_order(&rows, &registry_id, &workspace);
    let anchor_key = format!("{registry_id}/{anchor}");
    let anchor_index = order.iter().position(|key| *key == anchor_key)? as i64;
    Some(if after { anchor_index + 1 } else { anchor_index })
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
pub fn workspace_edge_anchor(edge: WorkspaceEdgeSide, workspace: String, order: Vec<String>) -> Option<WorkspaceAnchor> {
    if !order.contains(&workspace) {
        return None;
    }
    let (row, after) = match edge {
        WorkspaceEdgeSide::Top => (order.first()?, false),
        WorkspaceEdgeSide::Bottom => (order.last()?, true),
    };
    (*row != workspace).then(|| WorkspaceAnchor { anchor: row.clone(), after })
}

/// Move Workspace Above… / Below….
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WorkspaceNeighborSide {
    Above,
    Below,
}

/// The rows `workspace` can go next to on this side, in `order` (its
/// container): every other row except the one it already sits right after
/// (above) or right before (below).
#[uniffi::export]
pub fn workspace_neighbor_targets(side: WorkspaceNeighborSide, workspace: String, order: Vec<String>) -> Vec<String> {
    let Some(position) = order.iter().position(|id| *id == workspace) else { return Vec::new() };
    let skip = match side {
        WorkspaceNeighborSide::Above => position.checked_add(1),
        WorkspaceNeighborSide::Below => position.checked_sub(1),
    };
    order
        .into_iter()
        .enumerate()
        .filter(|(index, row)| *row != workspace && Some(*index) != skip)
        .map(|(_, row)| row)
        .collect()
}

/// `order` once `workspace` sits on this side of `target`; `order` as it was
/// when `target` is not in it.
#[uniffi::export]
pub fn workspace_neighbor_reordered(
    side: WorkspaceNeighborSide,
    workspace: String,
    target: String,
    order: Vec<String>,
) -> Vec<String> {
    let mut rows: Vec<String> = order.iter().filter(|id| **id != workspace).cloned().collect();
    let Some(at) = rows.iter().position(|id| *id == target) else { return order };
    rows.insert(if side == WorkspaceNeighborSide::Above { at } else { at + 1 }, workspace);
    rows
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

/// One move of a sort: `workspace` goes right before or after `anchor`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceSortStep {
    pub workspace: String,
    pub anchor: String,
    pub after: bool,
}

/// The moves that turn `order` (one container) into `sorted` (the same
/// rows), one row at a time as the Mac places them: the first row before the
/// container's current first row, each next one right after the one before
/// it. Rows already in place are not moved.
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
        let row = current.remove(at);
        current.insert(offset.min(current.len()), row);
    }
    steps
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
pub fn workspace_close_targets(kind: WorkspaceCloseKind, workspace: String, order: Vec<WorkspaceCloseRow>) -> Vec<u32> {
    let Some(index) = order.iter().position(|row| row.id == workspace) else { return Vec::new() };
    let group = order[index].group.as_deref();
    order
        .iter()
        .enumerate()
        .filter(|(i, row)| match kind {
            WorkspaceCloseKind::Others => row.id != workspace,
            WorkspaceCloseKind::Above => *i < index,
            WorkspaceCloseKind::Below => *i > index,
            WorkspaceCloseKind::OthersInGroup => group.is_some() && row.id != workspace && row.group.as_deref() == group,
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
