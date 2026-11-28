//! The rules behind the workspace row menu's New Workspace and Merge Workspace Into… on the
//! phone (verify/parity-mac.md, Workspaces): which places New Workspace offers beside a row,
//! which row a new workspace at Top or Bottom goes next to, and which workspaces a row can
//! merge into, in the Mac's sidebar order. Swift's `WorkspaceCreator` sends the moves; these
//! are its rules.

/// What the rules read of one workspace row.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceRowFacts {
    pub id: String,
    pub mac_id: String,
    /// Its place in the Mac's sidebar; nil sorts last, in list order.
    pub sidebar_index: Option<i64>,
    pub pinned: bool,
    pub home: bool,
    /// In a workspace group.
    pub grouped: bool,
    /// A create or close this phone sent is still on its way.
    pub pending: bool,
}

/// A place New Workspace offers beside a row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WorkspaceRowPlacement {
    Above,
    Below,
    Top,
    Bottom,
}

/// The places New Workspace offers beside a row: Above and Below a row this phone can
/// arrange, at Top and at Bottom of its Mac's sidebar. None for Home, a row the phone may not
/// arrange or a Mac it can't create on; only Top and Bottom for a pinned row (the Mac orders
/// its pinned tiles with a layout move a phone may not send).
#[uniffi::export]
pub fn workspace_row_placements(
    row: WorkspaceRowFacts,
    can_arrange: bool,
    can_create: bool,
) -> Vec<WorkspaceRowPlacement> {
    use WorkspaceRowPlacement as P;
    if !can_arrange || row.home || !can_create {
        return Vec::new();
    }
    if row.pinned { vec![P::Top, P::Bottom] } else { vec![P::Above, P::Below, P::Top, P::Bottom] }
}

/// `rows` that pass `keep`, in the Mac's sidebar order (no index last; ties in list order).
fn sidebar_order<'a>(
    rows: &'a [WorkspaceRowFacts],
    keep: impl Fn(&WorkspaceRowFacts) -> bool,
) -> Vec<&'a WorkspaceRowFacts> {
    let mut kept: Vec<(usize, &WorkspaceRowFacts)> =
        rows.iter().enumerate().filter(|(_, r)| keep(r)).collect();
    kept.sort_by_key(|(offset, r)| (r.sidebar_index.unwrap_or(i64::MAX), *offset));
    kept.into_iter().map(|(_, r)| r).collect()
}

/// The id of the row a new workspace goes before (top) or after (bottom): the first or last of
/// its Mac's unpinned rows other than Home and itself, in sidebar order. Nil when it is alone.
#[uniffi::export]
pub fn workspace_new_row_anchor(
    top: bool,
    workspace_id: String,
    mac_id: String,
    rows: Vec<WorkspaceRowFacts>,
) -> Option<String> {
    let rows = sidebar_order(&rows, |r| r.mac_id == mac_id && r.id != workspace_id && !r.pinned && !r.home);
    // Top: before the first loose row. A group shows before the row its `top_index` names, so a
    // new row put at a grouped first row's index would show after that group. Bottom: after the
    // last row, grouped or not (a group's run starts at its first member, so a row after its
    // last member shows after it).
    let anchor = if top { rows.iter().find(|r| !r.grouped).or(rows.first()) } else { rows.last() };
    anchor.map(|r| r.id.clone())
}

/// The ids of the workspaces a row can merge into: its Mac's others, never Home (the Mac's
/// `WorkspaceMerge.staysPut`) nor one still pending, in sidebar order.
#[uniffi::export]
pub fn workspace_merge_targets(
    workspace_id: String,
    mac_id: String,
    rows: Vec<WorkspaceRowFacts>,
) -> Vec<String> {
    sidebar_order(&rows, |r| r.mac_id == mac_id && r.id != workspace_id && !r.home && !r.pending)
        .into_iter()
        .map(|r| r.id.clone())
        .collect()
}

#[cfg(test)]
#[path = "workspace_row_actions_tests.rs"]
mod tests;
