//! Read-only mirror of one cmux-tui session's resource tree.
//!
//! The mirror starts from a `session.snapshot` (or a snapshot item on the
//! `session.events` stream) and applies `session.events` deltas in revision
//! order. It never mutates the daemon; the UI reads it and sends intents
//! through the SDK.
//!
//! Windows: `cmux.protocol/2` has no window resource. Windows are an app-side
//! concept (the Swift app keeps its window records in a frontend projection),
//! so the mirror keeps `frontend_projections` verbatim for a later stage and
//! models workspaces > screens > panes > tabs (> terminal | browser).
//!
//! Personal state: the mirror also keeps the workspace groups and the
//! personal sidebar order (workspace placements) from the snapshot's
//! `extra.state` and the `state_upsert` / `state_delete` changes
//! (`mirror_state`).

use crate::mirror_state::{self, StateChange};
use cmux::{
    BrowserId, BrowserSnapshot, ClientSnapshot, ConnectedClientId, Cursor, FrontendProjectionId,
    FrontendProjectionSnapshot, PaneId, PaneSnapshot, ResourceChange, ResourceEntitySnapshot,
    ResourceKind, ResourceReference, ResourceSnapshot, ScreenId, ScreenSnapshot, SessionDeltaEvent,
    SessionEvent, SessionSnapshot, TabId, TabSnapshot, TerminalId, TerminalSnapshot,
    WorkspaceGroupSnapshot, WorkspaceId, WorkspacePlacementSnapshot, WorkspaceSnapshot,
};
use std::collections::BTreeMap;
use std::fmt;

/// What one applied change did to one mirrored resource.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Change<I> {
    Added(I),
    Updated(I),
    Removed(I),
}

/// One typed change the mirror applied. A UI diffs only what these name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MirrorChange {
    Session,
    Workspace(Change<WorkspaceId>),
    Screen(Change<ScreenId>),
    Pane(Change<PaneId>),
    Tab(Change<TabId>),
    Terminal(Change<TerminalId>),
    Browser(Change<BrowserId>),
    Client(Change<ConnectedClientId>),
    FrontendProjection(Change<FrontendProjectionId>),
    /// A personal workspace group, by its state id (`grp_…`).
    WorkspaceGroup(Change<String>),
    /// A workspace's place in the personal sidebar order, by placement id
    /// (`<session registry id>/<workspace ref>`).
    WorkspacePlacement(Change<String>),
    /// A state resource the mirror does not keep (tab group, room, closed
    /// item, window record, ...), by its `resource` name.
    IgnoredState(String),
    /// A resource the mirror does not keep (machine, notification, agent,
    /// pairing request, sidebar view) or an unknown change kind.
    Ignored(Option<ResourceKind>),
}

/// Result of applying one session event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Applied {
    /// The whole mirror was replaced by a snapshot.
    Reset,
    /// A delta was applied; the listed changes happened in order.
    Delta(Vec<MirrorChange>),
    /// The event kind is unknown to this SDK build; the mirror is unchanged.
    Skipped,
}

/// The event cannot be applied; resubscribe from a fresh snapshot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MirrorError {
    /// A delta arrived before any snapshot.
    NoBaseline,
    /// The daemon restarted (new generation) without a snapshot item.
    GenerationChanged { mirror: String, event: String },
    /// A delta does not continue from the mirror's revision.
    RevisionGap { mirror: u64, previous: u64 },
    /// An upsert's value kind does not match its declared resource.
    Mismatch(ResourceKind),
    /// A state change of a kept resource is malformed.
    InvalidState { resource: String, reason: String },
}

impl fmt::Display for MirrorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoBaseline => write!(f, "delta before any snapshot"),
            Self::GenerationChanged { mirror, event } => {
                write!(f, "generation changed from {mirror} to {event} without a snapshot")
            }
            Self::RevisionGap { mirror, previous } => {
                write!(f, "delta continues revision {previous}, mirror is at {mirror}")
            }
            Self::Mismatch(kind) => write!(f, "upsert value does not match resource {kind:?}"),
            Self::InvalidState { resource, reason } => {
                write!(f, "invalid {resource} state change: {reason}")
            }
        }
    }
}

impl std::error::Error for MirrorError {}

/// Mirrored session state, keyed by opaque IDs.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Mirror {
    pub cursor: Option<Cursor>,
    pub session: Option<SessionSnapshot>,
    pub workspaces: BTreeMap<WorkspaceId, WorkspaceSnapshot>,
    pub screens: BTreeMap<ScreenId, ScreenSnapshot>,
    pub panes: BTreeMap<PaneId, PaneSnapshot>,
    pub tabs: BTreeMap<TabId, TabSnapshot>,
    pub terminals: BTreeMap<TerminalId, TerminalSnapshot>,
    pub browsers: BTreeMap<BrowserId, BrowserSnapshot>,
    pub clients: BTreeMap<ConnectedClientId, ClientSnapshot>,
    pub frontend_projections: BTreeMap<FrontendProjectionId, FrontendProjectionSnapshot>,
    /// Personal workspace groups by state id.
    pub workspace_groups: BTreeMap<String, WorkspaceGroupSnapshot>,
    /// The personal sidebar order by placement id. It can name workspaces
    /// of other sessions (`workspace.workspace_id` is `None` for those).
    pub workspace_placements: BTreeMap<String, WorkspacePlacementSnapshot>,
}

fn keyed<I: Ord, T>(items: Vec<T>, id: impl Fn(&T) -> I) -> BTreeMap<I, T> {
    items.into_iter().map(|item| (id(&item), item)).collect()
}

fn upsert<I: Ord + Clone, T>(map: &mut BTreeMap<I, T>, id: I, value: T) -> Change<I> {
    match map.insert(id.clone(), value) {
        Some(_) => Change::Updated(id),
        None => Change::Added(id),
    }
}

fn remove<I: Ord + Clone, T>(map: &mut BTreeMap<I, T>, id: &I) -> Option<Change<I>> {
    map.remove(id).map(|_| Change::Removed(id.clone()))
}

impl Mirror {
    pub fn from_snapshot(snapshot: ResourceSnapshot) -> Self {
        let mut mirror = Self::default();
        mirror.reset(snapshot);
        mirror
    }

    /// Replaces everything with `snapshot`.
    pub fn reset(&mut self, snapshot: ResourceSnapshot) {
        let (workspace_groups, workspace_placements) = mirror_state::from_extra(&snapshot.extra);
        *self = Self {
            cursor: Some(snapshot.cursor),
            session: Some(snapshot.session),
            workspaces: keyed(snapshot.workspaces, |w| w.id.clone()),
            screens: keyed(snapshot.screens, |s| s.id.clone()),
            panes: keyed(snapshot.panes, |p| p.id.clone()),
            tabs: keyed(snapshot.tabs, |t| t.id.clone()),
            terminals: keyed(snapshot.terminals, |t| t.id.clone()),
            browsers: keyed(snapshot.browsers, |b| b.id.clone()),
            clients: keyed(snapshot.clients, |c| c.id.clone()),
            frontend_projections: keyed(snapshot.frontend_projections, |p| p.id.clone()),
            workspace_groups,
            workspace_placements,
        };
    }

    pub fn revision(&self) -> Option<u64> {
        self.cursor.as_ref().map(|c| c.revision)
    }

    /// Applies one `session.events` item. On error the mirror is unchanged
    /// and the caller must resubscribe from a fresh snapshot.
    pub fn apply(&mut self, event: SessionEvent) -> Result<Applied, MirrorError> {
        match event {
            SessionEvent::Snapshot(snapshot) => {
                self.reset(snapshot.snapshot);
                // The item cursor is authoritative for where deltas resume.
                self.cursor = Some(snapshot.cursor);
                Ok(Applied::Reset)
            }
            SessionEvent::Delta(delta) => self.apply_delta(delta).map(Applied::Delta),
            SessionEvent::Unknown { .. } => Ok(Applied::Skipped),
        }
    }

    pub fn apply_delta(
        &mut self,
        delta: SessionDeltaEvent,
    ) -> Result<Vec<MirrorChange>, MirrorError> {
        let cursor = self.cursor.as_ref().ok_or(MirrorError::NoBaseline)?;
        if cursor.generation != delta.cursor.generation {
            return Err(MirrorError::GenerationChanged {
                mirror: cursor.generation.clone(),
                event: delta.cursor.generation,
            });
        }
        if delta.previous_revision != cursor.revision {
            return Err(MirrorError::RevisionGap {
                mirror: cursor.revision,
                previous: delta.previous_revision,
            });
        }
        // Validate (and decode state changes) before mutating so a bad delta
        // leaves the mirror intact.
        let mut states = Vec::with_capacity(delta.changes.len());
        for change in &delta.changes {
            states.push(match change {
                ResourceChange::Upsert { resource, value, .. } => {
                    if !value_matches(*resource, value) {
                        return Err(MirrorError::Mismatch(*resource));
                    }
                    None
                }
                ResourceChange::Unknown { kind, raw } => mirror_state::decode(kind, raw)?,
                ResourceChange::Delete { .. } => None,
            });
        }
        let mut applied = Vec::with_capacity(delta.changes.len());
        for (change, state) in delta.changes.into_iter().zip(states) {
            applied.push(match state {
                Some(state) => self.apply_state(state),
                None => self.apply_change(change),
            });
        }
        self.cursor = Some(delta.cursor);
        if let Some(session) = &mut self.session {
            session.revision = delta.revision;
        }
        Ok(applied)
    }

    fn apply_change(&mut self, change: ResourceChange) -> MirrorChange {
        use ResourceEntitySnapshot as V;
        match change {
            ResourceChange::Upsert { value, .. } => match value {
                V::Session(session) => {
                    self.session = Some(session);
                    MirrorChange::Session
                }
                V::Workspace(v) => {
                    MirrorChange::Workspace(upsert(&mut self.workspaces, v.id.clone(), v))
                }
                V::Screen(v) => MirrorChange::Screen(upsert(&mut self.screens, v.id.clone(), v)),
                V::Pane(v) => MirrorChange::Pane(upsert(&mut self.panes, v.id.clone(), v)),
                V::Tab(v) => MirrorChange::Tab(upsert(&mut self.tabs, v.id.clone(), v)),
                V::Terminal(v) => {
                    MirrorChange::Terminal(upsert(&mut self.terminals, v.id.clone(), v))
                }
                V::Browser(v) => MirrorChange::Browser(upsert(&mut self.browsers, v.id.clone(), v)),
                V::Client(v) => MirrorChange::Client(upsert(&mut self.clients, v.id.clone(), v)),
                V::FrontendProjection(v) => MirrorChange::FrontendProjection(upsert(
                    &mut self.frontend_projections,
                    v.id.clone(),
                    v,
                )),
                V::Machine(_) => MirrorChange::Ignored(Some(ResourceKind::Machine)),
                V::Notification(_) => MirrorChange::Ignored(Some(ResourceKind::Notification)),
                V::Agent(_) => MirrorChange::Ignored(Some(ResourceKind::Agent)),
                V::PairingRequest(_) => MirrorChange::Ignored(Some(ResourceKind::PairingRequest)),
                V::SidebarView(_) => MirrorChange::Ignored(Some(ResourceKind::SidebarView)),
            },
            ResourceChange::Delete { resource, id, .. } => {
                use ResourceReference as R;
                let removed = match &id {
                    R::Workspace(id) => {
                        remove(&mut self.workspaces, id).map(MirrorChange::Workspace)
                    }
                    R::Screen(id) => remove(&mut self.screens, id).map(MirrorChange::Screen),
                    R::Pane(id) => remove(&mut self.panes, id).map(MirrorChange::Pane),
                    R::Tab(id) => remove(&mut self.tabs, id).map(MirrorChange::Tab),
                    R::Terminal(id) => remove(&mut self.terminals, id).map(MirrorChange::Terminal),
                    R::Browser(id) => remove(&mut self.browsers, id).map(MirrorChange::Browser),
                    R::Client(id) => remove(&mut self.clients, id).map(MirrorChange::Client),
                    R::FrontendProjection(id) => remove(&mut self.frontend_projections, id)
                        .map(MirrorChange::FrontendProjection),
                    R::Session(_) => {
                        self.session = None;
                        Some(MirrorChange::Session)
                    }
                    _ => None,
                };
                // Deleting something already absent is not an error: the
                // stream is the authority and the end state is the same.
                removed.unwrap_or(MirrorChange::Ignored(Some(resource)))
            }
            ResourceChange::Unknown { .. } => MirrorChange::Ignored(None),
        }
    }

    fn apply_state(&mut self, change: StateChange) -> MirrorChange {
        match change {
            StateChange::GroupUpsert(id, group) => {
                MirrorChange::WorkspaceGroup(upsert(&mut self.workspace_groups, id, group))
            }
            StateChange::GroupDelete(id) => remove(&mut self.workspace_groups, &id).map_or_else(
                || MirrorChange::IgnoredState(mirror_state::WORKSPACE_GROUP.to_string()),
                MirrorChange::WorkspaceGroup,
            ),
            StateChange::PlacementUpsert(id, placement) => MirrorChange::WorkspacePlacement(
                upsert(&mut self.workspace_placements, id, placement),
            ),
            StateChange::PlacementDelete(id) => remove(&mut self.workspace_placements, &id)
                .map_or_else(
                    || MirrorChange::IgnoredState(mirror_state::WORKSPACE_PLACEMENT.to_string()),
                    MirrorChange::WorkspacePlacement,
                ),
            StateChange::Other(resource) => MirrorChange::IgnoredState(resource),
        }
    }

    // MARK: - Personal sidebar queries

    /// Workspace groups in order.
    pub fn workspace_groups_ordered(&self) -> Vec<&WorkspaceGroupSnapshot> {
        let mut out: Vec<_> = self.workspace_groups.values().collect();
        out.sort_by(|a, b| a.index.cmp(&b.index).then_with(|| a.id.cmp(&b.id)));
        out
    }

    /// Placements in the personal sidebar order.
    pub fn placements_ordered(&self) -> Vec<&WorkspacePlacementSnapshot> {
        let mut out: Vec<_> = self.workspace_placements.values().collect();
        out.sort_by(|a, b| {
            a.index
                .cmp(&b.index)
                .then_with(|| a.workspace.placement_id().cmp(&b.workspace.placement_id()))
        });
        out
    }

    /// The placement of a live workspace of this session.
    pub fn placement_of(&self, workspace: &WorkspaceId) -> Option<&WorkspacePlacementSnapshot> {
        self.workspace_placements
            .values()
            .find(|p| p.workspace.workspace_id.as_ref() == Some(workspace))
    }

    /// The live workspaces of this session in a group, in personal order.
    /// Members from other sessions are left out.
    pub fn group_members(&self, group: &str) -> Vec<WorkspaceId> {
        self.placements_ordered()
            .into_iter()
            .filter(|p| p.group_id.as_deref() == Some(group))
            .filter_map(|p| p.workspace.workspace_id.clone())
            .filter(|id| self.workspaces.contains_key(id))
            .collect()
    }

    /// This session's workspaces in the personal sidebar order: placed ones
    /// by placement index, then the unplaced ones in daemon order.
    pub fn workspaces_in_personal_order(&self) -> Vec<&WorkspaceSnapshot> {
        let mut out: Vec<&WorkspaceSnapshot> = self
            .placements_ordered()
            .into_iter()
            .filter_map(|p| p.workspace.workspace_id.as_ref())
            .filter_map(|id| self.workspaces.get(id))
            .collect();
        for workspace in self.workspaces_ordered() {
            if !out.iter().any(|w| w.id == workspace.id) {
                out.push(workspace);
            }
        }
        out
    }

    // MARK: - Ordered tree queries

    /// Workspaces in sidebar order.
    pub fn workspaces_ordered(&self) -> Vec<&WorkspaceSnapshot> {
        let mut out: Vec<_> = self.workspaces.values().collect();
        out.sort_by(|a, b| a.index.cmp(&b.index).then_with(|| a.id.cmp(&b.id)));
        out
    }

    pub fn screens_of(&self, workspace: &WorkspaceId) -> Vec<&ScreenSnapshot> {
        let mut out: Vec<_> =
            self.screens.values().filter(|s| &s.workspace_id == workspace).collect();
        out.sort_by(|a, b| a.index.cmp(&b.index).then_with(|| a.id.cmp(&b.id)));
        out
    }

    /// Panes of a screen, in its layout's leaf order when the layout names
    /// them, then any others by ID.
    pub fn panes_of(&self, screen: &ScreenId) -> Vec<&PaneSnapshot> {
        let mut out: Vec<_> = self.panes.values().filter(|p| &p.screen_id == screen).collect();
        let order =
            self.screens.get(screen).map(|s| layout_pane_order(&s.layout.root)).unwrap_or_default();
        out.sort_by_key(|p| {
            (order.iter().position(|id| id == &p.id).unwrap_or(usize::MAX), p.id.clone())
        });
        out
    }

    pub fn tabs_of(&self, pane: &PaneId) -> Vec<&TabSnapshot> {
        let mut out: Vec<_> = self.tabs.values().filter(|t| &t.pane_id == pane).collect();
        out.sort_by(|a, b| a.index.cmp(&b.index).then_with(|| a.id.cmp(&b.id)));
        out
    }

    /// One line per node, for logs.
    pub fn render_tree(&self) -> String {
        use std::fmt::Write;
        let mut out = String::new();
        let rev = self
            .cursor
            .as_ref()
            .map_or("-".to_string(), |c| format!("{}@{}", c.revision, c.generation));
        let name = self.session.as_ref().and_then(|s| s.name.clone()).unwrap_or_default();
        let _ = writeln!(out, "session {name} rev {rev}");
        let focus = |f: bool| if f { " *" } else { "" };
        for ws in self.workspaces_ordered() {
            let _ = writeln!(out, "  workspace {} {:?}{}", ws.id, ws.name, focus(ws.focused));
            for screen in self.screens_of(&ws.id) {
                let _ = writeln!(
                    out,
                    "    screen {} {:?}{}",
                    screen.id,
                    screen.name,
                    focus(screen.focused)
                );
                for pane in self.panes_of(&screen.id) {
                    let _ = writeln!(out, "      pane {}{}", pane.id, focus(pane.focused));
                    for tab in self.tabs_of(&pane.id) {
                        let title = match &tab.content_id {
                            cmux::TabContentId::Terminal(id) => {
                                self.terminals.get(id).map(|t| t.title.clone()).unwrap_or_default()
                            }
                            cmux::TabContentId::Browser(id) => {
                                self.browsers.get(id).map(|b| b.url.clone()).unwrap_or_default()
                            }
                        };
                        let _ = writeln!(
                            out,
                            "        tab {} {:?} {title:?}{}",
                            tab.id,
                            tab.content_kind,
                            focus(tab.focused)
                        );
                    }
                }
            }
        }
        out
    }
}

fn layout_pane_order(node: &cmux::LayoutNode) -> Vec<PaneId> {
    let mut out = Vec::new();
    collect_panes(node, &mut out);
    out
}

fn collect_panes(node: &cmux::LayoutNode, out: &mut Vec<PaneId>) {
    use cmux::LayoutNode as N;
    match node {
        N::Leaf(leaf) => out.push(leaf.pane_id.clone()),
        N::Split(split) => {
            collect_panes(&split.first, out);
            collect_panes(&split.second, out);
        }
        N::Stack(stack) => out.extend(stack.pane_ids.iter().cloned()),
        N::Viewport(viewport) => viewport.columns.iter().for_each(|c| collect_panes(&c.root, out)),
    }
}

/// Whether an upsert value is of the declared resource kind.
fn value_matches(kind: ResourceKind, value: &ResourceEntitySnapshot) -> bool {
    use ResourceEntitySnapshot as V;
    matches!(
        (kind, value),
        (ResourceKind::Machine, V::Machine(_))
            | (ResourceKind::Session, V::Session(_))
            | (ResourceKind::Workspace, V::Workspace(_))
            | (ResourceKind::Screen, V::Screen(_))
            | (ResourceKind::Pane, V::Pane(_))
            | (ResourceKind::Tab, V::Tab(_))
            | (ResourceKind::Terminal, V::Terminal(_))
            | (ResourceKind::Browser, V::Browser(_))
            | (ResourceKind::Client, V::Client(_))
            | (ResourceKind::Notification, V::Notification(_))
            | (ResourceKind::Agent, V::Agent(_))
            | (ResourceKind::PairingRequest, V::PairingRequest(_))
            | (ResourceKind::FrontendProjection, V::FrontendProjection(_))
            | (ResourceKind::SidebarView, V::SidebarView(_))
    )
}
