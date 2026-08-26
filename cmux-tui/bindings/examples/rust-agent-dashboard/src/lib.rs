mod model;

pub use model::{
    AgentSummary, AgentTransition, AgentUpdate, DashboardModel, ServerSummary, WorkspaceSummary,
    state_name,
};

use cmux::{
    AgentId, AgentState, Client, Config, CreationState, Error, MutationOptions, NotificationLevel,
    NotificationOptions, RunCommand, RunOptions as CmuxRunOptions, Session, TerminalId,
    TerminalSnapshot, TerminalWaitExitResult, Workspace,
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

#[derive(Debug, Clone)]
pub struct CommandCheckOptions {
    pub command: RunCommand,
    pub correlation_key: String,
    pub idempotency_key: String,
    pub exit_timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CommandCheckResult {
    pub terminal_id: TerminalId,
    pub recovered_creation: bool,
    pub wait: TerminalWaitExitResult,
    pub snapshot: TerminalSnapshot,
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
    let snapshot = session.snapshot()?;
    let server_changed = model.replace_server(snapshot.session);
    let workspace_changed = model.replace_workspaces(snapshot.workspaces);
    let update =
        model.replace_agents(snapshot.agents.into_iter().map(AgentSummary::from).collect());
    tracker.reconcile(model);
    notify_newly_blocked(session, model, &update.transitions, options.notify_blocked, tracker)?;
    Ok(server_changed || workspace_changed || update.changed)
}

fn notify_newly_blocked(
    session: &Session,
    model: &DashboardModel,
    transitions: &[AgentTransition],
    enabled: bool,
    tracker: &mut NotificationTracker,
) -> Result<()> {
    if !enabled {
        return Ok(());
    }
    for transition in transitions {
        if transition.current != AgentState::Blocked || tracker.blocked.contains(&transition.id) {
            continue;
        }
        let terminal_id =
            model.agents.get(&transition.id).map(|agent| agent.terminal_id.clone()).ok_or_else(
                || {
                    DashboardError::Invariant(format!(
                        "blocked agent {} disappeared before notification",
                        transition.id
                    ))
                },
            )?;
        session.create_notification(NotificationOptions {
            title: "Agent needs input".to_string(),
            body: format!("Agent {} is blocked.", transition.id),
            level: Some(NotificationLevel::Warning),
            terminal_id: Some(terminal_id),
        })?;
        tracker.blocked.insert(transition.id.clone());
    }
    Ok(())
}

/// Runs one command with reconnect-safe creation recovery and returns its exact
/// lifecycle snapshot after a bounded server-side exit wait.
pub fn run_command_check(
    session: &Session,
    workspace: &Workspace,
    options: CommandCheckOptions,
) -> Result<CommandCheckResult> {
    let run = CmuxRunOptions::command(options.command)
        .correlation_key(options.correlation_key.clone())?;
    let mutation = MutationOptions::new(options.idempotency_key.clone())?;
    let (terminal, recovered_creation) = match workspace.run_with(run, mutation) {
        Ok(created) => (created.resource, false),
        Err(error) => {
            let Error::MutationTransport { operation, idempotency_key, .. } = &error else {
                return Err(error.into());
            };
            if operation != "workspace.run" || idempotency_key != &options.idempotency_key {
                return Err(DashboardError::Invariant(format!(
                    "unexpected uncertain mutation {operation} with key {idempotency_key}"
                )));
            }
            let resolution = session.creation().resolve(options.correlation_key)?;
            if resolution.operation.as_deref().is_some_and(|value| value != "workspace.run") {
                return Err(DashboardError::Invariant(
                    "creation correlation resolved to a different operation".to_string(),
                ));
            }
            if resolution.state != CreationState::Created {
                return Err(DashboardError::Invariant(format!(
                    "creation is {:?}; recovery is {:?}",
                    resolution.state, resolution.recovery
                )));
            }
            let terminal_id = resolution
                .created_path
                .as_ref()
                .and_then(cmux::CreatedPath::terminal_id)
                .cloned()
                .ok_or_else(|| {
                    DashboardError::Invariant(
                        "created workspace.run resolution lacks a terminal path".to_string(),
                    )
                })?;
            (session.terminal(terminal_id), true)
        }
    };

    let terminal_id = terminal.id().cloned().ok_or_else(|| {
        DashboardError::Invariant("created terminal handle lacks an opaque ID".to_string())
    })?;
    let wait = terminal.wait_exit(options.exit_timeout_ms)?;
    let waited_id = match &wait {
        TerminalWaitExitResult::Pending(result) => &result.terminal_id,
        TerminalWaitExitResult::Exited(result) => &result.terminal_id,
    };
    if waited_id != &terminal_id {
        return Err(DashboardError::Invariant(format!(
            "terminal wait returned {waited_id} for {terminal_id}"
        )));
    }
    let snapshot = terminal.refresh()?;
    if snapshot.id != terminal_id {
        return Err(DashboardError::Invariant(format!(
            "terminal refresh returned {} for {terminal_id}",
            snapshot.id
        )));
    }
    Ok(CommandCheckResult { terminal_id, recovered_creation, wait, snapshot })
}

fn write_dashboard(output: &mut dyn Write, model: &DashboardModel, clear: bool) -> Result<()> {
    if clear {
        output.write_all(b"\x1b[2J\x1b[H")?;
    }
    output.write_all(model.render().as_bytes())?;
    output.flush()?;
    Ok(())
}
