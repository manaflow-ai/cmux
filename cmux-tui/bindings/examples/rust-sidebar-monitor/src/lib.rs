//! A lifecycle-complete external consumer of the public cmux sidebar APIs.

use cmux::{
    Error, MutationResult, Result, SidebarView, SidebarViewSnapshot, StreamEnd, StreamEndReason,
};
use cmux_sidebar::{
    SidebarConfig, SidebarModel, SidebarRuntime, SidebarRuntimeState, SidebarWidget,
};
use crossterm::event::Event;
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use std::thread;
use std::time::Duration;

/// Application-owned queue and recovery policy.
#[derive(Clone, Debug)]
pub struct MonitorConfig {
    pub queue_capacity: usize,
    pub max_recoveries: usize,
    pub recovery_delay: Duration,
    pub title: String,
}

impl Default for MonitorConfig {
    fn default() -> Self {
        Self {
            queue_capacity: 64,
            max_recoveries: 3,
            recovery_delay: Duration::from_millis(100),
            title: "cmux sidebar".to_string(),
        }
    }
}

/// Current lifecycle state, independent of the latest retained frame.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MonitorPhase {
    Connecting,
    Live,
    Recovering,
    Ended(StreamEndReason),
    Failed(String),
}

/// Application-owned metadata retained across attachment leases.
#[derive(Clone, Debug)]
pub struct MonitorStatus {
    pub phase: MonitorPhase,
    pub gap_recoveries: usize,
    pub local_queue_recoveries: usize,
    pub last_gap: Option<StreamEnd>,
    pub terminal_end: Option<StreamEnd>,
}

impl MonitorStatus {
    #[must_use]
    pub fn is_terminal(&self) -> bool {
        matches!(self.phase, MonitorPhase::Ended(_) | MonitorPhase::Failed(_))
    }
}

/// A sidebar runtime with an application-selected automatic recovery policy.
pub struct SidebarMonitor {
    runtime: SidebarRuntime,
    max_recoveries: usize,
    recovery_delay: Duration,
    status: MonitorStatus,
    terminal_handled: bool,
}

impl SidebarMonitor {
    /// Opens the initial attachment with the requested local queue bound.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid bounds or when the SDK cannot open the
    /// sidebar attachment.
    pub fn start(view: SidebarView, config: MonitorConfig) -> Result<Self> {
        if config.queue_capacity == 0 {
            return Err(Error::InvalidArgument(
                "monitor queue_capacity must be greater than zero".to_string(),
            ));
        }
        if config.max_recoveries == 0 {
            return Err(Error::InvalidArgument(
                "max_recoveries must be greater than zero".to_string(),
            ));
        }
        let runtime = SidebarRuntime::start(
            view,
            SidebarConfig {
                queue_capacity: config.queue_capacity,
                initial_columns: None,
                initial_rows: None,
                fallback_title: config.title,
            },
        )?;
        Ok(Self {
            runtime,
            max_recoveries: config.max_recoveries,
            recovery_delay: config.recovery_delay,
            status: MonitorStatus {
                phase: MonitorPhase::Connecting,
                gap_recoveries: 0,
                local_queue_recoveries: 0,
                last_gap: None,
                terminal_end: None,
            },
            terminal_handled: false,
        })
    }

    #[must_use]
    pub fn model(&self) -> &SidebarModel {
        self.runtime.model()
    }

    #[must_use]
    pub fn status(&self) -> &MonitorStatus {
        &self.status
    }

    #[must_use]
    pub fn widget(&self) -> SidebarWidget<'_> {
        self.runtime.widget().footer(Line::from(Span::styled(
            phase_label(&self.status.phase),
            phase_style(&self.status.phase),
        )))
    }

    /// Drains queued render data and applies the configured recovery policy.
    ///
    /// # Errors
    ///
    /// Returns an error when the recovery budget is exhausted or a fresh
    /// attachment cannot be opened.
    pub fn poll_updates(&mut self) -> Result<usize> {
        let applied = self.runtime.poll_updates();
        if self.terminal_handled {
            return Ok(applied);
        }
        match self.runtime.state().clone() {
            SidebarRuntimeState::Attached => {
                self.status.phase = MonitorPhase::Live;
            }
            SidebarRuntimeState::Ended(end) if end.reason == StreamEndReason::Gap => {
                self.status.gap_recoveries += 1;
                self.status.last_gap = Some(end);
                self.recover()?;
            }
            SidebarRuntimeState::QueueOverflow => {
                self.status.local_queue_recoveries += 1;
                self.recover()?;
            }
            SidebarRuntimeState::Ended(end) => {
                self.status.phase = MonitorPhase::Ended(end.reason);
                self.status.terminal_end = Some(end);
                self.terminal_handled = true;
            }
            SidebarRuntimeState::Failed(message) => {
                self.status.phase = MonitorPhase::Failed(message);
                self.terminal_handled = true;
            }
        }
        Ok(applied)
    }

    fn recover(&mut self) -> Result<()> {
        let attempts = self.status.gap_recoveries + self.status.local_queue_recoveries;
        if attempts > self.max_recoveries {
            let message = format!("attachment exceeded {} recoveries", self.max_recoveries);
            self.status.phase = MonitorPhase::Failed(message.clone());
            self.terminal_handled = true;
            return Err(Error::Connection(message));
        }
        self.status.phase = MonitorPhase::Recovering;
        if !self.recovery_delay.is_zero() {
            thread::sleep(self.recovery_delay);
        }
        if let Err(error) = self.runtime.reattach() {
            self.status.phase = MonitorPhase::Failed(error.to_string());
            self.terminal_handled = true;
            return Err(error);
        }
        self.status.phase = MonitorPhase::Live;
        Ok(())
    }

    /// Forwards one supported Crossterm event to the sidebar.
    ///
    /// # Errors
    ///
    /// Returns an error when the input cannot be encoded or delivered.
    pub fn handle_event(&self, event: &Event) -> Result<bool> {
        self.runtime.handle_event(event)
    }

    /// Resizes the remote sidebar viewport.
    ///
    /// # Errors
    ///
    /// Returns an error for zero dimensions or a failed mutation.
    pub fn resize(&self, columns: u16, rows: u16) -> Result<()> {
        self.runtime.resize(columns, rows)
    }

    /// Reloads the process that supplies the sidebar view.
    ///
    /// # Errors
    ///
    /// Returns an error when the reload mutation fails.
    pub fn reload(&self) -> Result<MutationResult<SidebarViewSnapshot>> {
        self.runtime.view().reload()
    }

    /// Cancels the current attachment and waits for its worker to stop.
    ///
    /// # Errors
    ///
    /// Returns an error when cancellation fails or the worker panics.
    pub fn shutdown(self) -> Result<()> {
        self.runtime.shutdown()
    }
}

fn phase_label(phase: &MonitorPhase) -> String {
    match phase {
        MonitorPhase::Connecting => "connecting".to_string(),
        MonitorPhase::Live => "live".to_string(),
        MonitorPhase::Recovering => "recovering".to_string(),
        MonitorPhase::Ended(reason) => format!("ended: {reason:?}").to_lowercase(),
        MonitorPhase::Failed(message) => format!("failed: {message}"),
    }
}

fn phase_style(phase: &MonitorPhase) -> Style {
    let color = match phase {
        MonitorPhase::Live => Color::Green,
        MonitorPhase::Connecting | MonitorPhase::Recovering => Color::Yellow,
        MonitorPhase::Ended(_) => Color::DarkGray,
        MonitorPhase::Failed(_) => Color::Red,
    };
    Style::default().fg(color)
}
