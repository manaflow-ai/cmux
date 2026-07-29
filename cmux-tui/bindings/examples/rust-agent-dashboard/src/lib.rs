mod model;

pub use model::{
    AgentSummary, AgentTransition, AgentUpdate, DashboardModel, ServerSummary, WorkspaceSummary,
    state_name,
};

use cmux::{
    AgentId, AgentListOptions, AgentState, Client, Config, Error, NotificationLevel,
    NotificationOptions, Selector, Session,
};
use std::collections::BTreeSet;
use std::fmt;
use std::io::{self, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

pub type Result<T> = std::result::Result<T, DashboardError>;

#[derive(Debug)]
pub enum DashboardError {
    Sdk(Error),
    Io(io::Error),
    Invariant(String),
}

impl fmt::Display for DashboardError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sdk(error) => write!(formatter, "{error}"),
            Self::Io(error) => write!(formatter, "{error}"),
            Self::Invariant(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for DashboardError {}

impl From<Error> for DashboardError {
    fn from(error: Error) -> Self {
        Self::Sdk(error)
    }
}

impl From<io::Error> for DashboardError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

#[derive(Debug, Clone)]
pub struct RunOptions {
    pub agent_poll_interval: Duration,
    pub watch_for: Option<Duration>,
    pub clear_screen: bool,
    pub notify_blocked: bool,
}

impl Default for RunOptions {
    fn default() -> Self {
        Self {
            agent_poll_interval: Duration::from_secs(1),
            watch_for: None,
            clear_screen: true,
            notify_blocked: false,
        }
    }
}

#[derive(Debug, Default)]
pub struct NotificationTracker {
    blocked: BTreeSet<AgentId>,
}

impl NotificationTracker {
    fn reconcile(&mut self, model: &DashboardModel) {
        self.blocked.retain(|id| {
            model.agents.get(id).is_some_and(|agent| agent.state == AgentState::Blocked)
        });
    }
}

pub fn run_connection(
    config: Config,
    options: &RunOptions,
    shutdown: &AtomicBool,
    notifications: &mut NotificationTracker,
    output: &mut dyn Write,
) -> Result<()> {
    if options.agent_poll_interval.is_zero() {
        return Err(DashboardError::Invariant(
            "agent poll interval must be greater than zero".to_string(),
        ));
    }

    let client = Client::connect(config)?;
    let result = run_connected(&client, options, shutdown, notifications, output);
    let close = client.close();
    result?;
    close?;
    Ok(())
}

fn run_connected(
    client: &Client,
    options: &RunOptions,
    shutdown: &AtomicBool,
    notifications: &mut NotificationTracker,
    output: &mut dyn Write,
) -> Result<()> {
    let session = client.current_session();
    let mut model = DashboardModel::new(session.refresh()?);
    refresh(&session, &mut model, options, notifications)?;
    write_dashboard(output, &model, options.clear_screen)?;

    let started = Instant::now();
    let deadline = options.watch_for.map(|duration| started + duration);
    let mut next_refresh = started + options.agent_poll_interval;
    loop {
        let now = Instant::now();
        if shutdown.load(Ordering::Acquire) || deadline.is_some_and(|end| now >= end) {
            return Ok(());
        }
        if now >= next_refresh {
            let changed = refresh(&session, &mut model, options, notifications)?;
            if changed {
                model.status = "resource snapshots refreshed".to_string();
                write_dashboard(output, &model, options.clear_screen)?;
            }
            next_refresh = now + options.agent_poll_interval;
            continue;
        }

        let mut wait = Duration::from_millis(50).min(next_refresh.saturating_duration_since(now));
        if let Some(end) = deadline {
            wait = wait.min(end.saturating_duration_since(now));
        }
        if !wait.is_zero() {
            thread::sleep(wait);
        }
    }
}

pub fn run_with_reconnect(
    config: Config,
    options: &RunOptions,
    reconnect_delay: Duration,
    shutdown: Arc<AtomicBool>,
    output: &mut dyn Write,
    errors: &mut dyn Write,
) -> Result<()> {
    let mut notifications = NotificationTracker::default();
    loop {
        match run_connection(config.clone(), options, shutdown.as_ref(), &mut notifications, output)
        {
            Ok(()) => return Ok(()),
            Err(_error) if shutdown.load(Ordering::Acquire) => return Ok(()),
            Err(error) => {
                writeln!(
                    errors,
                    "dashboard connection failed: {error}; retrying in {} ms",
                    reconnect_delay.as_millis()
                )?;
            }
        }

        let retry_at = Instant::now() + reconnect_delay;
        while Instant::now() < retry_at {
            if shutdown.load(Ordering::Acquire) {
                return Ok(());
            }
            thread::sleep(
                Duration::from_millis(50).min(retry_at.saturating_duration_since(Instant::now())),
            );
        }
    }
}

fn refresh(
    session: &Session,
    model: &mut DashboardModel,
    options: &RunOptions,
    tracker: &mut NotificationTracker,
) -> Result<bool> {
    let workspaces = session
        .workspaces()?
        .into_iter()
        .map(|workspace| workspace.refresh())
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let workspace_changed = model.replace_workspaces(workspaces);
    let update = model.replace_agents(load_agents(session)?);
    tracker.reconcile(model);
    notify_newly_blocked(session, &update.transitions, options.notify_blocked, tracker)?;
    Ok(workspace_changed || update.changed)
}

fn load_agents(session: &Session) -> Result<Vec<AgentSummary>> {
    let mut result = Vec::new();
    for state in [
        AgentState::Working,
        AgentState::Blocked,
        AgentState::Idle,
        AgentState::Done,
        AgentState::Unknown,
    ] {
        for agent in session.agents(AgentListOptions { terminal_id: None, state: Some(state) })? {
            let id = match agent.selector() {
                Selector::Id(id) => id.clone(),
                Selector::Current(_) | Selector::Name(_) => {
                    return Err(DashboardError::Invariant(
                        "agent.list returned a non-ID resource handle".to_string(),
                    ));
                }
            };
            result.push(AgentSummary { id, state });
        }
    }
    Ok(result)
}

fn notify_newly_blocked(
    session: &Session,
    transitions: &[AgentTransition],
    enabled: bool,
    tracker: &mut NotificationTracker,
) -> Result<()> {
    if !enabled {
        return Ok(());
    }
    for transition in transitions {
        if transition.current != AgentState::Blocked
            || !tracker.blocked.insert(transition.id.clone())
        {
            continue;
        }
        session.create_notification(NotificationOptions {
            title: "Agent needs input".to_string(),
            body: format!("Agent {} is blocked.", transition.id),
            level: Some(NotificationLevel::Warning),
            terminal_id: None,
        })?;
    }
    Ok(())
}

fn write_dashboard(output: &mut dyn Write, model: &DashboardModel, clear: bool) -> Result<()> {
    if clear {
        output.write_all(b"\x1b[2J\x1b[H")?;
    }
    output.write_all(model.render().as_bytes())?;
    output.flush()?;
    Ok(())
}
