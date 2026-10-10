//! Keeps an agent's identity while job control moves it out of the foreground.
//!
//! Adapted from herdr's `src/pane/background_agent.rs` and the
//! `process_start_token` / `live_pane_process_group` functions of
//! `src/platform/{linux,macos}.rs` at commit
//! `950d012cf0cfd17737b4fff2f4982210b50b5794` (herdr
//! https://github.com/ogulcancelik/herdr, Apache-2.0, see `manifests/LICENSE`).
//! Modified by manaflow: agents are manifest ids instead of a closed enum, and
//! the held-agent replacement case is left to the scanner's existing
//! process-group edge (a new job always has a new group), so this port has no
//! separate `ReplacedInFront` status.
//!
//! Suspending an agent with ctrl-z, or running a command in front of it, hands
//! the terminal to another job while the agent process lives on. Treating that
//! as an exit would close the agent's row; nothing would restore it when the
//! job returns to the foreground. While the agent is held, the visible screen
//! belongs to the other job and says nothing about the agent's state.

/// Where the process that identified as the current agent is now, when the
/// foreground probe no longer finds that agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AgentJobStatus {
    /// Untracked, still in the foreground, or gone without having been held.
    Unknown,
    /// Alive outside the foreground, such as a job stopped with ctrl-z.
    Background,
    /// Was held in the background and has since exited.
    ExitedInBackground,
}

/// The identified agent process. The start token tells it apart from a later
/// process that reuses its pid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct AgentProcess {
    pid: u32,
    start_token: u64,
}

/// Process facts used to tell a backgrounded agent from an exited one.
pub(crate) trait AgentProcessLiveness {
    fn start_token(&self, pid: u32) -> Option<u64>;
    /// Process group of `pid` while that same process, matched by its start
    /// token, is alive in the terminal session of `shell_pid`. A stopped or
    /// backgrounded job still counts.
    fn live_process_group(&self, shell_pid: u32, pid: u32, start_token: u64) -> Option<u32>;
}

/// One process probe, as the scanner saw it.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ProbeObservation<'a> {
    /// The PTY child, normally the pane shell.
    pub shell_pid: u32,
    /// The agent the tracker still holds from earlier probes.
    pub current_agent: Option<&'a str>,
    /// The agent this probe identified, if any.
    pub identified_agent: Option<&'a str>,
    /// The process that identified as `identified_agent`.
    pub identified_pid: Option<u32>,
    /// The current foreground process group, when the platform proved it.
    pub foreground_group: Option<u32>,
}

#[derive(Debug, Default)]
pub(crate) struct AgentJobTracker {
    process: Option<AgentProcess>,
    in_background: bool,
}

impl AgentJobTracker {
    /// `agent_missing` means the probe lost a current agent whose exit has not
    /// been confirmed. Liveness is checked only then, never per scan.
    pub(crate) fn status(
        &self,
        agent_missing: bool,
        shell_pid: u32,
        foreground_group: Option<u32>,
        live_group: impl FnOnce(u32, u32, u64) -> Option<u32>,
    ) -> AgentJobStatus {
        if !agent_missing {
            return AgentJobStatus::Unknown;
        }
        let Some(process) = self.process else {
            return AgentJobStatus::Unknown;
        };
        match live_group(shell_pid, process.pid, process.start_token) {
            // An agent in the shell's own group was never a separate job, and
            // one still in the foreground group is a plain miss.
            Some(group) if group != shell_pid && Some(group) != foreground_group => {
                AgentJobStatus::Background
            }
            Some(_) => AgentJobStatus::Unknown,
            None if self.in_background => AgentJobStatus::ExitedInBackground,
            None => AgentJobStatus::Unknown,
        }
    }

    pub(crate) fn observe(
        &mut self,
        status: AgentJobStatus,
        current_agent: Option<&str>,
        identified_agent: Option<&str>,
        identified_pid: Option<u32>,
        start_token: impl FnOnce(u32) -> Option<u64>,
    ) {
        if current_agent.is_none() && identified_agent.is_none() {
            *self = Self::default();
        } else if identified_agent.is_some() {
            self.in_background = false;
            // Reread every time: a new process may have reused the pid.
            self.process = identified_pid.and_then(|pid| {
                start_token(pid).map(|start_token| AgentProcess { pid, start_token })
            });
        } else if status == AgentJobStatus::Background {
            self.in_background = true;
        }
    }

    /// Apply one probe and return whether the current agent is alive in the
    /// background, so its identity must be kept and its screen not read.
    pub(crate) fn hold(
        &mut self,
        probe: ProbeObservation<'_>,
        processes: &impl AgentProcessLiveness,
    ) -> bool {
        // Without a proven foreground group the platform cannot tell a
        // background job from the foreground one.
        let agent_missing = probe.current_agent.is_some()
            && probe.identified_agent.is_none()
            && probe.foreground_group.is_some();
        let status =
            self.status(agent_missing, probe.shell_pid, probe.foreground_group, |s, p, t| {
                processes.live_process_group(s, p, t)
            });
        self.observe(
            status,
            probe.current_agent,
            probe.identified_agent,
            probe.identified_pid.filter(|_| probe.foreground_group.is_some()),
            |pid| processes.start_token(pid),
        );
        status == AgentJobStatus::Background
    }
}

/// The host process table.
pub(crate) struct PlatformProcesses;

impl AgentProcessLiveness for PlatformProcesses {
    fn start_token(&self, pid: u32) -> Option<u64> {
        platform::process_start_token(pid)
    }

    fn live_process_group(&self, shell_pid: u32, pid: u32, start_token: u64) -> Option<u32> {
        platform::live_pane_process_group(shell_pid, pid, start_token)
    }
}

#[cfg(target_os = "linux")]
mod platform {
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub(super) struct ProcessJobStat {
        pub(super) state: char,
        pub(super) pgrp: i32,
        pub(super) session: i32,
        pub(super) start_time: u64,
    }

    /// Start time of `pid` in clock ticks since boot.
    pub(super) fn process_start_token(pid: u32) -> Option<u64> {
        process_job_stat(pid).map(|stat| stat.start_time)
    }

    pub(super) fn live_pane_process_group(
        shell_pid: u32,
        pid: u32,
        start_token: u64,
    ) -> Option<u32> {
        let stat = process_job_stat(pid)?;
        let shell_session = process_job_stat(shell_pid)?.session;
        (!matches!(stat.state, 'Z' | 'X')
            && stat.start_time == start_token
            && stat.session == shell_session
            && stat.pgrp > 0)
            .then_some(stat.pgrp as u32)
    }

    fn process_job_stat(pid: u32) -> Option<ProcessJobStat> {
        // /proc/<pid>/stat is one short line; it is not attacker-sized.
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        process_job_stat_from_stat(&stat)
    }

    pub(super) fn process_job_stat_from_stat(stat: &str) -> Option<ProcessJobStat> {
        let rest = stat.get(stat.rfind(')')? + 2..)?;
        let fields: Vec<&str> = rest.split_whitespace().collect();
        // After (comm): state(0) ppid(1) pgrp(2) session(3) ... starttime(19)
        Some(ProcessJobStat {
            state: fields.first()?.chars().next()?,
            pgrp: fields.get(2)?.parse().ok()?,
            session: fields.get(3)?.parse().ok()?,
            start_time: fields.get(19)?.parse().ok()?,
        })
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use std::mem::size_of;

    /// `SZOMB` from `<sys/proc.h>`.
    const SZOMB: u32 = 5;

    /// Start time of `pid` in microseconds.
    pub(super) fn process_start_token(pid: u32) -> Option<u64> {
        process_bsdinfo(pid).map(|info| bsdinfo_start_token(&info))
    }

    pub(super) fn live_pane_process_group(
        shell_pid: u32,
        pid: u32,
        start_token: u64,
    ) -> Option<u32> {
        let process = process_bsdinfo(pid)?;
        let shell = process_bsdinfo(shell_pid)?;
        (process.pbi_status != SZOMB
            && bsdinfo_start_token(&process) == start_token
            && process.e_tdev == shell.e_tdev)
            .then_some(process.pbi_pgid)
    }

    fn bsdinfo_start_token(info: &libc::proc_bsdinfo) -> u64 {
        info.pbi_start_tvsec.saturating_mul(1_000_000).saturating_add(info.pbi_start_tvusec)
    }

    fn process_bsdinfo(pid: u32) -> Option<libc::proc_bsdinfo> {
        let mut info = unsafe { std::mem::zeroed::<libc::proc_bsdinfo>() };
        let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
        // SAFETY: `info` is a writable proc_bsdinfo of exactly `size` bytes.
        let written = unsafe {
            libc::proc_pidinfo(
                pid as libc::c_int,
                libc::PROC_PIDTBSDINFO,
                0,
                (&mut info as *mut libc::proc_bsdinfo).cast(),
                size,
            )
        };
        (written == size).then_some(info)
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod platform {
    pub(super) fn process_start_token(_pid: u32) -> Option<u64> {
        None
    }

    pub(super) fn live_pane_process_group(
        _shell_pid: u32,
        _pid: u32,
        _start_token: u64,
    ) -> Option<u32> {
        None
    }
}
