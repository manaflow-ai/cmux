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
    #[cfg(test)]
    pub(crate) fn in_background(&self) -> bool {
        self.in_background
    }

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

#[cfg(test)]
mod tests {
    use super::*;

    const SHELL: u32 = 10;
    const WRAPPER_JOB: u32 = 20;
    const AGENT_PID: u32 = 21;
    const AGENT_START: u64 = 7_000;

    fn acquired(agent: &str) -> AgentJobTracker {
        let mut tracker = AgentJobTracker::default();
        tracker.observe(
            AgentJobStatus::Unknown,
            Some(agent),
            Some(agent),
            Some(AGENT_PID),
            |pid| (pid == AGENT_PID).then_some(AGENT_START),
        );
        tracker
    }

    fn live_agent(shell: u32, pid: u32, start_token: u64) -> Option<u32> {
        assert_eq!(shell, SHELL);
        (pid == AGENT_PID && start_token == AGENT_START).then_some(WRAPPER_JOB)
    }

    struct FakeProcesses {
        alive: bool,
    }

    impl AgentProcessLiveness for FakeProcesses {
        fn start_token(&self, pid: u32) -> Option<u64> {
            (pid == AGENT_PID).then_some(AGENT_START)
        }

        fn live_process_group(&self, shell: u32, pid: u32, token: u64) -> Option<u32> {
            if self.alive { live_agent(shell, pid, token) } else { None }
        }
    }

    fn probe<'a>(current: Option<&'a str>, identified: Option<&'a str>) -> ProbeObservation<'a> {
        ProbeObservation {
            shell_pid: SHELL,
            current_agent: current,
            identified_agent: identified,
            identified_pid: identified.map(|_| AGENT_PID),
            foreground_group: Some(if identified.is_some() { WRAPPER_JOB } else { SHELL }),
        }
    }

    #[test]
    fn stopped_agent_behind_the_shell_is_in_background() {
        let tracker = acquired("claude");
        assert_eq!(
            tracker.status(true, SHELL, Some(SHELL), live_agent),
            AgentJobStatus::Background
        );
    }

    #[test]
    fn agent_that_exited_in_front_is_unknown() {
        let tracker = acquired("claude");
        assert_eq!(
            tracker.status(true, SHELL, Some(SHELL), |_, _, _| None),
            AgentJobStatus::Unknown
        );
    }

    #[test]
    fn liveness_is_only_checked_when_the_agent_went_missing() {
        let tracker = acquired("claude");
        let no_check = |_: u32, _: u32, _: u64| -> Option<u32> { panic!("liveness checked") };
        assert_eq!(tracker.status(false, SHELL, Some(SHELL), no_check), AgentJobStatus::Unknown);
        assert_eq!(
            AgentJobTracker::default().status(true, SHELL, Some(SHELL), no_check),
            AgentJobStatus::Unknown
        );
    }

    #[test]
    fn agent_still_in_the_foreground_group_or_the_shell_group_is_not_held() {
        let tracker = acquired("claude");
        assert_eq!(
            tracker.status(true, SHELL, Some(WRAPPER_JOB), live_agent),
            AgentJobStatus::Unknown
        );
        assert_eq!(
            acquired("pi").status(true, SHELL, Some(30), |_, _, _| Some(SHELL)),
            AgentJobStatus::Unknown
        );
    }

    #[test]
    fn agent_without_a_start_token_is_never_held() {
        let mut tracker = AgentJobTracker::default();
        tracker.observe(AgentJobStatus::Unknown, Some("pi"), Some("pi"), Some(AGENT_PID), |_| None);
        assert_eq!(
            tracker.status(true, SHELL, Some(SHELL), |_, _, _| Some(WRAPPER_JOB)),
            AgentJobStatus::Unknown
        );
    }

    #[test]
    fn reidentified_agent_refreshes_its_start_token() {
        const REUSED_START: u64 = 9_000;
        let mut tracker = acquired("pi");
        tracker.observe(AgentJobStatus::Unknown, Some("pi"), Some("pi"), Some(AGENT_PID), |_| {
            Some(REUSED_START)
        });
        assert_eq!(
            tracker.status(true, SHELL, Some(SHELL), |_, pid, token| {
                (pid == AGENT_PID && token == REUSED_START).then_some(WRAPPER_JOB)
            }),
            AgentJobStatus::Background
        );
    }

    #[test]
    fn returning_agent_ends_the_hold_and_a_cleared_agent_resets() {
        let mut tracker = acquired("claude");
        let status = tracker.status(true, SHELL, Some(SHELL), live_agent);
        tracker.observe(status, Some("claude"), None, None, |_| None);
        assert!(tracker.in_background());
        tracker.observe(
            AgentJobStatus::Unknown,
            Some("claude"),
            Some("claude"),
            Some(AGENT_PID),
            |_| None,
        );
        assert!(!tracker.in_background());

        let mut tracker = acquired("pi");
        let status = tracker.status(true, SHELL, Some(SHELL), live_agent);
        tracker.observe(status, Some("pi"), None, None, |_| None);
        tracker.observe(AgentJobStatus::Unknown, None, None, None, |_| None);
        assert!(!tracker.in_background());
        assert_eq!(tracker.status(true, SHELL, Some(SHELL), live_agent), AgentJobStatus::Unknown);
    }

    #[test]
    fn hold_keeps_a_suspended_agent_until_it_exits() {
        let mut tracker = AgentJobTracker::default();
        let alive = FakeProcesses { alive: true };
        assert!(!tracker.hold(probe(None, Some("codex")), &alive), "acquisition is not a hold");
        assert!(
            tracker.hold(probe(Some("codex"), None), &alive),
            "ctrl-z hands the pane to the shell"
        );
        assert!(
            tracker.hold(probe(Some("codex"), None), &alive),
            "every later probe keeps holding"
        );
        assert!(!tracker.hold(probe(Some("codex"), Some("codex")), &alive), "fg returns it");
        assert!(!tracker.in_background());

        assert!(tracker.hold(probe(Some("codex"), None), &alive));
        let gone = FakeProcesses { alive: false };
        assert!(!tracker.hold(probe(Some("codex"), None), &gone), "a killed job is not held");
        assert_eq!(
            tracker.status(true, SHELL, Some(SHELL), |_, _, _| None),
            AgentJobStatus::ExitedInBackground
        );
        assert!(!tracker.hold(probe(None, None), &gone));
        assert!(!tracker.in_background(), "the confirmed exit resets the tracker");
    }

    #[test]
    fn hold_needs_a_proven_foreground_group() {
        let mut tracker = AgentJobTracker::default();
        let alive = FakeProcesses { alive: true };
        let mut acquisition = probe(None, Some("codex"));
        acquisition.foreground_group = None;
        tracker.hold(acquisition, &alive);
        let mut missing = probe(Some("codex"), None);
        missing.foreground_group = None;
        assert!(!tracker.hold(missing, &alive));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn proc_stat_parsing_reads_job_fields_and_start_time() {
        let stat =
            "123 (node ) x) T 1 456 789 34816 456 4194560 1 2 3 4 5 6 7 8 20 0 11 0 987654 0 0";
        assert_eq!(
            platform::process_job_stat_from_stat(stat),
            Some(platform::ProcessJobStat {
                state: 'T',
                pgrp: 456,
                session: 789,
                start_time: 987654,
            })
        );
        assert_eq!(platform::process_job_stat_from_stat("123 (short) S 1 456 789"), None);
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn live_pane_process_group_follows_the_agent_process_not_its_job() {
        use std::os::unix::process::CommandExt;

        let processes = PlatformProcesses;
        let shell_pid = std::process::id();
        let mut wrapper =
            std::process::Command::new("sleep").arg("30").process_group(0).spawn().unwrap();
        let job = wrapper.id();
        let mut agent = std::process::Command::new("sleep")
            .arg("30")
            .process_group(job as i32)
            .spawn()
            .unwrap();
        let agent_pid = agent.id();
        let token = processes.start_token(agent_pid).expect("agent start token");

        assert_eq!(processes.live_process_group(shell_pid, agent_pid, token), Some(job));
        assert_eq!(processes.live_process_group(shell_pid, agent_pid, token + 1), None);
        // SAFETY: signals a child this test spawned and still owns.
        unsafe { libc::kill(agent_pid as libc::pid_t, libc::SIGSTOP) };
        assert_eq!(processes.live_process_group(shell_pid, agent_pid, token), Some(job));
        // SAFETY: as above.
        unsafe { libc::kill(agent_pid as libc::pid_t, libc::SIGKILL) };
        agent.wait().unwrap();
        assert_eq!(processes.live_process_group(shell_pid, agent_pid, token), None);
        let _ = wrapper.kill();
        let _ = wrapper.wait();
    }
}
