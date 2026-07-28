mod model;

pub use model::{
    AgentSummary, AgentTransition, AgentUpdate, DashboardModel, RefreshPlan, ServerSummary,
    WorkspaceSummary, state_name,
};

use cmux_client::{
    AgentState, ClientConfig, CmuxClient, CmuxError, ListAgentsRequest, NotificationLevel,
    NotifyRequest, Optional, SubscriptionBuilder,
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
    Sdk(CmuxError),
    Io(io::Error),
    Stream(String),
}

impl fmt::Display for DashboardError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sdk(error) => write!(formatter, "{error}"),
            Self::Io(error) => write!(formatter, "{error}"),
            Self::Stream(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for DashboardError {}

impl From<CmuxError> for DashboardError {
    fn from(error: CmuxError) -> Self {
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
    blocked: BTreeSet<u64>,
}

impl NotificationTracker {
    fn reconcile(&mut self, model: &DashboardModel) {
        self.blocked.retain(|surface| {
            model.agents.get(surface).is_some_and(|agent| agent.state == AgentState::Blocked)
        });
    }
}

pub fn run_connection(
    config: ClientConfig,
    options: &RunOptions,
    shutdown: &AtomicBool,
    notifications: &mut NotificationTracker,
    output: &mut dyn Write,
) -> Result<()> {
    if options.agent_poll_interval.is_zero() {
        return Err(DashboardError::Stream(
            "agent poll interval must be greater than zero".to_string(),
        ));
    }

    let mut client = CmuxClient::connect(config)?;
    let identify = client.identify_server()?;

    // Register before fetching snapshots. The SDK buffers events that race the
    // subscribe acknowledgement, so applying the snapshot and then draining
    // the stream has no topology gap.
    let mut stream = SubscriptionBuilder::deltas().open(&mut client)?;
    let mut model = DashboardModel::new(&identify);
    model.replace_tree(client.workspace_tree()?);
    let update = model.replace_agents(client.list_agents(ListAgentsRequest::default())?.agents);
    notifications.reconcile(&model);
    notify_newly_blocked(
        &mut client,
        &model,
        &update.transitions,
        options.notify_blocked,
        notifications,
    )?;
    write_dashboard(output, &model, options.clear_screen)?;

    let started = Instant::now();
    let deadline = options.watch_for.map(|duration| started + duration);
    let mut next_agent_poll = Instant::now() + options.agent_poll_interval;
    loop {
        let now = Instant::now();
        if shutdown.load(Ordering::Acquire) || deadline.is_some_and(|end| now >= end) {
            stream.close();
            client.close();
            return Ok(());
        }

        if now >= next_agent_poll {
            let update =
                model.replace_agents(client.list_agents(ListAgentsRequest::default())?.agents);
            notifications.reconcile(&model);
            notify_newly_blocked(
                &mut client,
                &model,
                &update.transitions,
                options.notify_blocked,
                notifications,
            )?;
            if update.changed {
                model.status = "agent snapshot refreshed".to_string();
                write_dashboard(output, &model, options.clear_screen)?;
            }
            next_agent_poll = now + options.agent_poll_interval;
            continue;
        }

        let mut timeout =
            Duration::from_millis(250).min(next_agent_poll.saturating_duration_since(now));
        if let Some(end) = deadline {
            timeout = timeout.min(end.saturating_duration_since(now));
        }
        if timeout.is_zero() {
            continue;
        }

        let event = match stream.recv_timeout(timeout) {
            Ok(event) => event,
            Err(CmuxError::Timeout(_)) => continue,
            Err(error) => return Err(error.into()),
        };
        let refresh = model.apply_event(&event);
        if refresh.tree {
            model.replace_tree(client.workspace_tree()?);
        }
        if refresh.agents {
            let agent_update =
                model.replace_agents(client.list_agents(ListAgentsRequest::default())?.agents);
            notifications.reconcile(&model);
            notify_newly_blocked(
                &mut client,
                &model,
                &agent_update.transitions,
                options.notify_blocked,
                notifications,
            )?;
            next_agent_poll = Instant::now() + options.agent_poll_interval;
        }
        write_dashboard(output, &model, options.clear_screen)?;
        if refresh.reconnect {
            stream.close();
            client.close();
            return Err(DashboardError::Stream(
                "subscription overflowed; reconnecting from fresh snapshots".to_string(),
            ));
        }
    }
}

pub fn run_with_reconnect(
    config: ClientConfig,
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

fn notify_newly_blocked(
    client: &mut CmuxClient,
    model: &DashboardModel,
    transitions: &[AgentTransition],
    enabled: bool,
    tracker: &mut NotificationTracker,
) -> Result<()> {
    if !enabled {
        return Ok(());
    }
    for transition in transitions {
        if transition.current != AgentState::Blocked || !tracker.blocked.insert(transition.surface)
        {
            continue;
        }
        let session = model
            .agents
            .get(&transition.surface)
            .and_then(|agent| agent.session.as_deref())
            .unwrap_or("unknown");
        client.notify(NotifyRequest {
            body: format!("Agent session {session} is blocked on surface {}.", transition.surface),
            level: Optional::Value(NotificationLevel::Warning),
            surface: Optional::Value(transition.surface),
            title: "Agent needs input".to_string(),
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
