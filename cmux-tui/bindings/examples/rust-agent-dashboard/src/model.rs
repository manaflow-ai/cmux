use cmux::{AgentId, AgentState, SessionSnapshot, WorkspaceSnapshot};
use std::collections::BTreeMap;
use std::fmt::Write as _;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerSummary {
    pub id: cmux::SessionId,
    pub name: Option<String>,
    pub revision: Option<u64>,
}

impl From<SessionSnapshot> for ServerSummary {
    fn from(snapshot: SessionSnapshot) -> Self {
        Self { id: snapshot.id, name: snapshot.name, revision: snapshot.revision }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceSummary {
    pub id: cmux::WorkspaceId,
    pub name: String,
}

impl From<WorkspaceSnapshot> for WorkspaceSummary {
    fn from(snapshot: WorkspaceSnapshot) -> Self {
        let name = snapshot.name.clone().unwrap_or_else(|| snapshot.id.to_string());
        Self { id: snapshot.id, name }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentSummary {
    pub id: AgentId,
    pub state: AgentState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentTransition {
    pub id: AgentId,
    pub previous: Option<AgentState>,
    pub current: AgentState,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AgentUpdate {
    pub changed: bool,
    pub transitions: Vec<AgentTransition>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DashboardModel {
    pub server: ServerSummary,
    pub workspaces: BTreeMap<cmux::WorkspaceId, WorkspaceSummary>,
    pub agents: BTreeMap<AgentId, AgentSummary>,
    pub status: String,
}

impl DashboardModel {
    pub fn new(server: SessionSnapshot) -> Self {
        Self {
            server: ServerSummary::from(server),
            workspaces: BTreeMap::new(),
            agents: BTreeMap::new(),
            status: "connected".to_string(),
        }
    }

    pub fn replace_workspaces(&mut self, snapshots: Vec<WorkspaceSnapshot>) -> bool {
        let next = snapshots
            .into_iter()
            .map(WorkspaceSummary::from)
            .map(|workspace| (workspace.id.clone(), workspace))
            .collect();
        let changed = self.workspaces != next;
        self.workspaces = next;
        changed
    }

    pub fn replace_agents(&mut self, records: Vec<AgentSummary>) -> AgentUpdate {
        let next: BTreeMap<_, _> =
            records.into_iter().map(|agent| (agent.id.clone(), agent)).collect();
        let transitions = next
            .iter()
            .filter_map(|(id, agent)| {
                let previous = self.agents.get(id).map(|prior| prior.state);
                (previous != Some(agent.state)).then(|| AgentTransition {
                    id: id.clone(),
                    previous,
                    current: agent.state,
                })
            })
            .collect();
        let changed = self.agents != next;
        self.agents = next;
        AgentUpdate { changed, transitions }
    }

    pub fn render(&self) -> String {
        let blocked =
            self.agents.values().filter(|agent| agent.state == AgentState::Blocked).count();
        let done = self.agents.values().filter(|agent| agent.state == AgentState::Done).count();
        let mut output = String::new();
        let session_name = self.server.name.as_deref().unwrap_or("<unnamed>");
        let revision =
            self.server.revision.map_or_else(|| "-".to_string(), |value| value.to_string());
        let _ = writeln!(
            output,
            "cmux agents | session {} ({}) | revision {}",
            flatten(session_name),
            self.server.id,
            revision
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
            let _ = writeln!(output, "  {} [{}]", flatten(&workspace.name), workspace.id);
        }

        let _ = writeln!(output, "agents:");
        if self.agents.is_empty() {
            let _ = writeln!(output, "  (none)");
        }
        let mut agents: Vec<_> = self.agents.values().collect();
        agents.sort_by_key(|agent| (state_rank(agent.state), agent.id.clone()));
        for agent in agents {
            let _ = writeln!(
                output,
                "{} {:<7} {}",
                state_marker(agent.state),
                state_name(agent.state),
                agent.id
            );
        }
        let _ = writeln!(output, "status: {}", flatten(&self.status));
        output
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

fn flatten(value: &str) -> String {
    value.replace(['\r', '\n'], " ")
}
