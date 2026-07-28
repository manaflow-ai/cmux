use cmux_client::{AgentRecord, AgentState, Event, IdentifyResult, Pane, Screen, Tree, Workspace};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerSummary {
    pub app: String,
    pub version: String,
    pub protocol: u32,
    pub session: String,
}

impl From<&IdentifyResult> for ServerSummary {
    fn from(server: &IdentifyResult) -> Self {
        Self {
            app: server.app.clone(),
            version: server.version.clone(),
            protocol: server.protocol,
            session: server.session.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceSummary {
    pub id: u64,
    pub short_id: Option<String>,
    pub name: String,
    pub active: bool,
    pub surfaces: BTreeSet<u64>,
}

impl WorkspaceSummary {
    fn from_workspace(workspace: &Workspace) -> Self {
        let mut surfaces = BTreeSet::new();
        for screen in &workspace.screens {
            extend_screen_surfaces(&mut surfaces, screen);
        }
        Self {
            id: workspace.id,
            short_id: workspace.short_id.clone(),
            name: workspace.name.clone(),
            active: workspace.active,
            surfaces,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentSummary {
    pub surface: u64,
    pub state: AgentState,
    pub source: cmux_client::AgentSource,
    pub session: Option<String>,
    pub updated_at_ms: u64,
}

impl From<AgentRecord> for AgentSummary {
    fn from(agent: AgentRecord) -> Self {
        Self {
            surface: agent.surface,
            state: agent.state,
            source: agent.source,
            session: agent.session.into_option(),
            updated_at_ms: agent.updated_at_ms,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentTransition {
    pub surface: u64,
    pub previous: Option<AgentState>,
    pub current: AgentState,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AgentUpdate {
    pub changed: bool,
    pub transitions: Vec<AgentTransition>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RefreshPlan {
    pub tree: bool,
    pub agents: bool,
    pub reconnect: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DashboardModel {
    pub server: ServerSummary,
    pub workspaces: BTreeMap<u64, WorkspaceSummary>,
    pub agents: BTreeMap<u64, AgentSummary>,
    pub status: String,
}

impl DashboardModel {
    pub fn new(server: &IdentifyResult) -> Self {
        Self {
            server: ServerSummary::from(server),
            workspaces: BTreeMap::new(),
            agents: BTreeMap::new(),
            status: "connected".to_string(),
        }
    }

    pub fn replace_tree(&mut self, tree: Tree) {
        self.workspaces = tree
            .workspaces
            .iter()
            .map(|workspace| (workspace.id, WorkspaceSummary::from_workspace(workspace)))
            .collect();
    }

    pub fn replace_agents(&mut self, records: Vec<AgentRecord>) -> AgentUpdate {
        let next: BTreeMap<_, _> = records
            .into_iter()
            .map(AgentSummary::from)
            .map(|agent| (agent.surface, agent))
            .collect();
        let mut transitions = Vec::new();
        for (&surface, agent) in &next {
            let previous = self.agents.get(&surface).map(|prior| prior.state);
            if previous != Some(agent.state) {
                transitions.push(AgentTransition { surface, previous, current: agent.state });
            }
        }
        let changed = self.agents != next;
        self.agents = next;
        AgentUpdate { changed, transitions }
    }

    pub fn apply_event(&mut self, event: &Event) -> RefreshPlan {
        let mut refresh = RefreshPlan::default();
        match event {
            Event::WorkspaceAdded(delta) => {
                self.workspaces
                    .insert(delta.workspace, WorkspaceSummary::from_workspace(&delta.entity));
                refresh.agents = true;
            }
            Event::WorkspaceMoved(delta) => {
                self.workspaces
                    .insert(delta.workspace, WorkspaceSummary::from_workspace(&delta.entity));
                refresh.agents = true;
            }
            Event::WorkspaceRenamed(delta) => {
                self.workspaces
                    .insert(delta.workspace, WorkspaceSummary::from_workspace(&delta.entity));
                refresh.agents = true;
            }
            Event::WorkspaceClosed(delta) => {
                self.workspaces.remove(&delta.workspace);
                refresh.agents = true;
            }
            Event::ScreenAdded(delta) => {
                if let Some(workspace) = self.workspaces.get_mut(&delta.workspace) {
                    extend_screen_surfaces(&mut workspace.surfaces, &delta.entity);
                } else {
                    refresh.tree = true;
                }
                refresh.agents = true;
            }
            Event::ScreenClosed(delta) => {
                if let Some(workspace) = self.workspaces.get_mut(&delta.workspace) {
                    remove_screen_surfaces(&mut workspace.surfaces, &delta.entity);
                } else {
                    refresh.tree = true;
                }
                refresh.agents = true;
            }
            Event::PaneAdded(delta) => {
                if let Some(workspace) = self.workspaces.get_mut(&delta.workspace) {
                    extend_pane_surfaces(&mut workspace.surfaces, &delta.entity);
                } else {
                    refresh.tree = true;
                }
                refresh.agents = true;
            }
            Event::PaneClosed(delta) => {
                if let Some(workspace) = self.workspaces.get_mut(&delta.workspace) {
                    remove_pane_surfaces(&mut workspace.surfaces, &delta.entity);
                } else {
                    refresh.tree = true;
                }
                refresh.agents = true;
            }
            Event::TabAdded(delta) => {
                if let Some(workspace) = self.workspaces.get_mut(&delta.workspace) {
                    workspace.surfaces.insert(delta.surface);
                } else {
                    refresh.tree = true;
                }
                refresh.agents = true;
            }
            Event::TabClosed(delta) => {
                if let Some(workspace) = self.workspaces.get_mut(&delta.workspace) {
                    workspace.surfaces.remove(&delta.surface);
                } else {
                    refresh.tree = true;
                }
                self.agents.remove(&delta.surface);
                refresh.agents = true;
            }
            Event::SurfaceExited(delta) => {
                for workspace in self.workspaces.values_mut() {
                    workspace.surfaces.remove(&delta.surface);
                }
                self.agents.remove(&delta.surface);
                refresh.agents = true;
            }
            Event::TreeChanged(_) => {
                refresh.tree = true;
                refresh.agents = true;
            }
            Event::Overflow(delta) => {
                self.status = format!("subscription overflow: {}", flatten(&delta.error));
                refresh.tree = true;
                refresh.agents = true;
                refresh.reconnect = true;
            }
            Event::Status(delta) => {
                self.status = flatten(&delta.message);
            }
            Event::Unknown(delta) => {
                let name = delta.name.as_deref().unwrap_or("<missing>");
                self.status = match &delta.decode_error {
                    Some(error) => {
                        format!("ignored malformed {name} event: {}", flatten(error))
                    }
                    None => format!("ignored future {name} event"),
                };
            }
            Event::Notification(delta) => {
                self.status =
                    format!("notification {}: {}", delta.notification, flatten(&delta.title));
            }
            _ => {}
        }
        refresh
    }

    pub fn render(&self) -> String {
        let blocked =
            self.agents.values().filter(|agent| agent.state == AgentState::Blocked).count();
        let done = self.agents.values().filter(|agent| agent.state == AgentState::Done).count();
        let mut output = String::new();
        let _ = writeln!(
            output,
            "cmux agents | {} {} | session {} | protocol {}",
            flatten(&self.server.app),
            flatten(&self.server.version),
            flatten(&self.server.session),
            self.server.protocol
        );
        let _ = writeln!(
            output,
            "workspaces {} | agents {} | blocked {} | done {}",
            self.workspaces.len(),
            self.agents.len(),
            blocked,
            done
        );
        let _ = writeln!(output, "workspaces:");
        if self.workspaces.is_empty() {
            let _ = writeln!(output, "  (none)");
        }
        for workspace in self.workspaces.values() {
            let marker = if workspace.active { ">" } else { " " };
            let reference = workspace
                .short_id
                .as_deref()
                .map(flatten)
                .unwrap_or_else(|| workspace.id.to_string());
            let _ = writeln!(
                output,
                "{marker} {} [{}] {} surfaces",
                flatten(&workspace.name),
                reference,
                workspace.surfaces.len()
            );
        }

        let _ = writeln!(output, "agents:");
        if self.agents.is_empty() {
            let _ = writeln!(output, "  (none)");
        }
        let mut agents: Vec<_> = self.agents.values().collect();
        agents.sort_by_key(|agent| (state_rank(agent.state), agent.surface));
        for agent in agents {
            let workspace = self.workspace_for_surface(agent.surface).unwrap_or("-");
            let upstream = agent.session.as_deref().map(flatten).unwrap_or_else(|| "-".to_string());
            let _ = writeln!(
                output,
                "{} surface:{} {:<7} workspace:{} session:{} source:{:?}",
                state_marker(agent.state),
                agent.surface,
                state_name(agent.state),
                flatten(workspace),
                upstream,
                agent.source
            );
        }
        let _ = writeln!(output, "status: {}", flatten(&self.status));
        output
    }

    fn workspace_for_surface(&self, surface: u64) -> Option<&str> {
        self.workspaces
            .values()
            .find(|workspace| workspace.surfaces.contains(&surface))
            .map(|workspace| workspace.name.as_str())
    }
}

pub fn state_name(state: AgentState) -> &'static str {
    match state {
        AgentState::Working => "working",
        AgentState::Blocked => "blocked",
        AgentState::Idle => "idle",
        AgentState::Done => "done",
        AgentState::Unknown => "unknown",
    }
}

fn state_marker(state: AgentState) -> &'static str {
    match state {
        AgentState::Blocked => "!",
        AgentState::Done => "✓",
        AgentState::Working => "●",
        AgentState::Idle => "○",
        AgentState::Unknown => "?",
    }
}

fn state_rank(state: AgentState) -> u8 {
    match state {
        AgentState::Blocked => 0,
        AgentState::Working => 1,
        AgentState::Idle => 2,
        AgentState::Done => 3,
        AgentState::Unknown => 4,
    }
}

fn extend_screen_surfaces(surfaces: &mut BTreeSet<u64>, screen: &Screen) {
    for pane in &screen.panes {
        extend_pane_surfaces(surfaces, pane);
    }
}

fn remove_screen_surfaces(surfaces: &mut BTreeSet<u64>, screen: &Screen) {
    for pane in &screen.panes {
        remove_pane_surfaces(surfaces, pane);
    }
}

fn extend_pane_surfaces(surfaces: &mut BTreeSet<u64>, pane: &Pane) {
    if let Pane::LivePane(pane) = pane {
        surfaces.extend(pane.tabs.iter().map(|tab| tab.surface));
    }
}

fn remove_pane_surfaces(surfaces: &mut BTreeSet<u64>, pane: &Pane) {
    if let Pane::LivePane(pane) = pane {
        for tab in &pane.tabs {
            surfaces.remove(&tab.surface);
        }
    }
}

fn flatten(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    for character in input.chars() {
        match character {
            '\n' | '\r' | '\t' => output.push(' '),
            character if character.is_control() => {
                for escaped in character.escape_default() {
                    output.push(escaped);
                }
            }
            character => output.push(character),
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_client::{
        AgentSource, LivePane, Nullable, Optional, Screen, Tab, TabBrowserSource, TabKind,
    };

    fn identify() -> IdentifyResult {
        IdentifyResult {
            app: "cmux-tui".to_string(),
            build_commit: Optional::Missing,
            capabilities: Some(Vec::new()),
            daemon_handoff: 1,
            generation: "generation".to_string(),
            ghostty_commit: Optional::Missing,
            pid: 42,
            protocol: 10,
            registry_id: "registry".to_string(),
            session: "test".to_string(),
            terminal_revision: 0,
            version: "0.1.0".to_string(),
            workspace_revision: 1,
        }
    }

    fn tab(surface: u64) -> Tab {
        Tab {
            browser_error: Optional::Missing,
            browser_frames_stalled: Optional::Missing,
            browser_source: Nullable::<TabBrowserSource>::null(),
            browser_status: Optional::Missing,
            dead: false,
            kind: TabKind::Pty,
            name: Nullable::null(),
            notification: Optional::Missing,
            short_id: None,
            size: Nullable::null(),
            surface,
            terminal_id: Optional::Missing,
            terminal_incarnation: Optional::Missing,
            title: format!("surface {surface}"),
        }
    }

    fn workspace(surface: u64) -> Workspace {
        Workspace {
            active: true,
            id: 1,
            key: None,
            name: "build".to_string(),
            screens: vec![Screen {
                active: true,
                active_pane: 3,
                id: 2,
                layout: cmux_client::Layout::Leaf { pane: 3 },
                name: Nullable::null(),
                panes: vec![Pane::LivePane(LivePane {
                    active_tab: 0,
                    focused_at: None,
                    id: 3,
                    name: Nullable::null(),
                    short_id: None,
                    tabs: vec![tab(surface)],
                })],
                short_id: None,
                zoomed_pane: Nullable::null(),
            }],
            short_id: Some("w1".to_string()),
        }
    }

    fn agent(surface: u64, state: AgentState) -> AgentRecord {
        AgentRecord {
            session: Nullable::value("upstream".to_string()),
            source: AgentSource::Hook,
            state,
            surface,
            updated_at_ms: 100,
        }
    }

    #[test]
    fn snapshots_join_agents_to_workspaces_and_prioritize_blocked_agents() {
        let mut model = DashboardModel::new(&identify());
        model.replace_tree(Tree {
            generation: None,
            pane_revision: None,
            registry_id: None,
            terminal_revision: None,
            workspace_revision: None,
            workspaces: vec![workspace(9)],
        });
        model.replace_agents(vec![agent(10, AgentState::Done), agent(9, AgentState::Blocked)]);

        let rendered = model.render();
        assert!(rendered.contains("blocked 1 | done 1"));
        assert!(rendered.contains("surface:9 blocked workspace:build"));
        assert!(
            rendered.find("surface:9").expect("blocked")
                < rendered.find("surface:10").expect("done")
        );
    }

    #[test]
    fn agent_replacement_reports_transitions_and_removes_stale_records() {
        let mut model = DashboardModel::new(&identify());
        model.replace_agents(vec![agent(9, AgentState::Working), agent(10, AgentState::Idle)]);
        let update = model.replace_agents(vec![agent(9, AgentState::Blocked)]);

        assert!(update.changed);
        assert_eq!(
            update.transitions,
            vec![AgentTransition {
                surface: 9,
                previous: Some(AgentState::Working),
                current: AgentState::Blocked,
            }]
        );
        assert!(!model.agents.contains_key(&10));
    }

    #[test]
    fn surface_exit_updates_topology_and_agent_state_without_raw_json() {
        let mut model = DashboardModel::new(&identify());
        model.replace_tree(Tree {
            generation: None,
            pane_revision: None,
            registry_id: None,
            terminal_revision: None,
            workspace_revision: None,
            workspaces: vec![workspace(9)],
        });
        model.replace_agents(vec![agent(9, AgentState::Working)]);

        let refresh = model
            .apply_event(&Event::SurfaceExited(cmux_client::SurfaceExitedEvent { surface: 9 }));

        assert!(refresh.agents);
        assert!(model.workspaces[&1].surfaces.is_empty());
        assert!(model.agents.is_empty());
    }

    #[test]
    fn renderer_neutralizes_terminal_control_characters() {
        let mut server = identify();
        server.session = "bad\u{1b}[2J\nsession".to_string();
        let model = DashboardModel::new(&server);

        let rendered = model.render();
        assert!(!rendered.contains('\u{1b}'));
        assert!(rendered.contains("\\u{1b}[2J session"));
    }
}
