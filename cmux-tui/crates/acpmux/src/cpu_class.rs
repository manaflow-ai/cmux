//! The CPU class a session's harness runs at (macOS). Agent harnesses and the tools they run
//! (builds, tests) otherwise compete with cmux and its Chromium renderers at the same priority,
//! and a busy Mac makes a dragged pane's page trail it (cmuxterm-hq#4947: p95 55 ms with 14 busy
//! processes at the default class, 6 ms with the same load at background class).
//!
//! `background` (the default) puts the harness in `PRIO_DARWIN_BG`, as cmux-git starts its git
//! children (`cmux-git` `run.rs`): the lowest CPU priority, throttled disk I/O and
//! background-class new sockets. `normal` leaves the harness at its starter's class.
//!
//! The start never runs at background class. A caller may retain a real hazard bound, and a
//! background harness can miss it on a busy disk: on 2026-10-30 (load 125 on 18 cores, `du` and
//! `git` scans of a 3.3 TB disk)
//! a `claude` harness at `PRIO_DARWIN_BG` spent 90 s in its trust-settings reads (`open()` and a
//! plist parse at disk tier 3) with under 1 s of CPU, and every Chief turn failed; the same
//! command at normal class answered in 14.5 s. So:
//!
//! 1. The harness starts at the daemon's class (its agent host starts there too and takes no
//!    utility clamp, `qos.rs`: a person waits on a start) and keeps no background class it would
//!    inherit: between fork and exec it
//!    clears one set on its starter by the starter itself (an agent host under
//!    `ACPMUX_QOS=background`, [`start_at_normal`]), and right after the spawn the daemon clears
//!    one that another process set ([`clear_running`]; a process cannot clear that one itself).
//!    The exec and the harness's own start run at normal CPU class. Disk I/O stays at the
//!    host's `IOPOL_UTILITY` (`qos.rs`): utility, not throttled.
//! 2. Once the session's start is over (its `initialize` and `session/new` or `session/load`
//!    answered, `hub/lifecycle.rs` `ensure_child`), the daemon puts the running harness in its
//!    class ([`CpuClass::enter`]): `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`, which
//!    macOS allows on another process of the same user. A `normal` harness goes to the agent
//!    tier's nice instead (`qos::AGENT_NICE`: +11 on macOS, the utility clamp's base priority;
//!    +5 on Linux, and its host's session group), with its whole process group in one
//!    `setpriority(PRIO_PGRP)`: the processes it started during its start, its MCP servers and a
//!    launcher's agent, at its own priority as under the clamp they replace. Every process the harness starts after
//!    that inherits it, so the builds and tests of its turns run below the GUI. A process it
//!    started during its start keeps the class it started at: an MCP server, and the real agent
//!    of a harness that is only a launcher (a script or adapter that starts the agent as a child
//!    and waits for it), whose turns then run at normal class. acpmux does not list processes
//!    (`scripts/cmux-next/check-no-process-scan.py`), so only the harness itself is reniced, once.
//!    So a Claude Code launcher defaults to `normal` ([`default_for`]): lowering it cannot reach
//!    its agent's tools, and it can carry the agent's stream. `sr2 claude` relays Claude Code's
//!    stdin and stdout, so at background class on a busy Mac (2026-11-08, load 450 on 15 cores)
//!    what Claude Code wrote reached acpmux 6.5 s late at the median and 54 s at p90, against
//!    0.1 s at p90 for the relays moved back to normal class in the same minutes. A tool call
//!    whose PreToolUse hook got no answer within its 90 s was refused ("hook did not respond").
//! 3. A cold start that still fails or misses its deadline with its harness at background class
//!    (set again during the start by another process) is retried once, and the retry is logged.
//! 4. A start that misses its deadline says what its harness was doing ([`HarnessSeen`]): alive or
//!    not, its class and priority, how long it ran, its CPU time and its threads on a CPU.
//! 5. What a harness did is read over its whole process tree, never its first process alone: a
//!    launcher (`sr2 claude`) does nothing itself while the agent it started does the work. And a
//!    page-in is work: on 2026-11-04 (swap 26.8 of 27.6 GB full, about 60 `git fetch` processes
//!    of 0.5 to 1.5 GB each) every Chief start failed at 90 s with "0.1 s of CPU, 0 of 12 threads
//!    running", read off the `sr2` launcher, while its `claude` was in uninterruptible page-in
//!    waits (ps state `U`, 24 MB resident after 14 minutes). Such a harness is slow, not hung.
//!    The cost: any process of the tree that works (an MCP server's timer) keeps a hung harness
//!    counted as working, so that case falls to its caller's longer bound (Chief's start ceiling,
//!    the pool's `START_HAZARD`).
//!
//! The class, first set wins: the profile's env `ACPMUX_SESSION_CPU_CLASS` as the harness gets it
//! (its `${env:…}` references resolved; one build-heavy profile can opt out), the daemon's env
//! `ACPMUX_SESSION_CPU_CLASS`, config `session.cpuClass`
//! (`acpmux config --set session.cpu_class=normal`), then [`default_for`] the harness:
//! `background`, or `normal` for a Claude Code launcher. Linux sessions get their
//! CPU share from their cgroup scope's `CPUWeight` instead (`session_scope.rs`), and other
//! platforms start harnesses as before: there the class is read and ignored.

use serde::{Deserialize, Serialize};

/// The knob, in a profile's env or the daemon's.
pub const ENV: &str = "ACPMUX_SESSION_CPU_CLASS";

/// The CPU class a session's harness runs at once its start is over.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CpuClass {
    /// Its starter's class: acpmux lowers nothing.
    #[default]
    Normal,
    /// `PRIO_DARWIN_BG` on macOS, from the end of its start on.
    Background,
}

/// The class a session runs at when nothing names one, and its harness is no launcher.
pub const DEFAULT: CpuClass = CpuClass::Background;

/// Where Claude Code's installers keep its files (as `harness_health/channel.rs` lists them). A
/// path into one of them is Claude Code under another name: the native installer's `claude` is a
/// symlink to `versions/<version>`, and a remote chain's `argv[0]` is the resolved file.
const CLAUDE_INSTALLS: &[&str] =
    &["/.local/share/claude/", "/.claude/local/", "/@anthropic-ai/claude-code/"];

/// The class a harness runs at when nothing names one (module docs, item 2). What the profile
/// says decides, never what another process is named. A Claude Code profile whose `argv` does not
/// start with Claude Code is a launcher. A wrapper that execs Claude Code reads as one too, and
/// then it and its tools run at normal class; its profile can still ask for `background`.
/// It reads the profile's `argv`, not the spawned program: a remote chain spawns `sandbox-exec`
/// whatever the profile runs. An empty `argv` runs `claude` (`claude_stdio::spawn_plan`).
pub fn default_for(kind: crate::config::HarnessKind, argv: &[String]) -> CpuClass {
    let launcher = kind == crate::config::HarnessKind::ClaudeStdio
        && argv.first().is_some_and(|program| {
            let name = std::path::Path::new(program).file_name().and_then(|name| name.to_str());
            !matches!(name, Some("claude" | "claude.exe"))
                && !CLAUDE_INSTALLS.iter().any(|install| program.contains(install))
        });
    if launcher { CpuClass::Normal } else { DEFAULT }
}

impl CpuClass {
    /// `normal` or `background` (any case, trimmed); None for anything else.
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "normal" => Some(Self::Normal),
            "background" => Some(Self::Background),
            _ => None,
        }
    }

    /// The class of a session whose harness has `kind` and `argv` in its profile and gets the
    /// environment `harness_env` (the command's complete one: the profile's values resolved, the daemon's own
    /// `ACPMUX_*` removed), with the daemon's env and config read now (at each spawn, as the
    /// session scope's limits are).
    #[cfg(target_os = "macos")]
    pub fn for_session<'a>(
        kind: crate::config::HarnessKind,
        argv: &[String],
        harness_env: impl IntoIterator<Item = (&'a str, &'a str)>,
    ) -> Self {
        let profile = harness_env.into_iter().find(|(k, _)| *k == ENV).map(|(_, v)| v);
        let config = crate::config::Config::load().ok().and_then(|c| c.session.cpu_class);
        Self::resolve(profile, std::env::var(ENV).ok(), config, default_for(kind, argv))
    }

    /// Off macOS: `normal`, with nothing read.
    #[cfg(not(target_os = "macos"))]
    pub fn for_session<'a>(
        _kind: crate::config::HarnessKind,
        _argv: &[String],
        _harness_env: impl IntoIterator<Item = (&'a str, &'a str)>,
    ) -> Self {
        Self::Normal
    }

    /// The first valid of the profile's value, the daemon's env value and config's, else
    /// `default`. A value that names no class is skipped, with a warning.
    pub fn resolve(
        profile: Option<&str>,
        daemon: Option<String>,
        config: Option<Self>,
        default: Self,
    ) -> Self {
        let named = |source: &str, value: Option<&str>| {
            let value = value?;
            let class = Self::parse(value);
            if class.is_none() {
                tracing::warn!("{source} {ENV}={value:?} names no CPU class (normal, background)");
            }
            class
        };
        named("profile env", profile)
            .or_else(|| named("daemon env", daemon.as_deref()))
            .or(config)
            .unwrap_or(default)
    }

    /// Puts the running harness `pid` in this class once its session's start is over, and only
    /// lowers: its process group at the agent tier's nice value (`qos::AGENT_NICE`; on Linux its
    /// host's session too) unless `ACPMUX_QOS=off`, then for `Background` the harness in
    /// background class (macOS). The start itself ran at the daemon's tier (`qos.rs`). `pid` must
    /// be a harness its caller holds (a direct child not reaped yet, or one its agent host reports
    /// alive): a pid that another process took would be lowered instead. True when it was lowered.
    pub fn enter(self, pid: u32) -> bool {
        // Both classes leave the start's priority for the agent tier: on Linux that is all the
        // lowering there is (it has no background class), and on macOS it takes the processes the
        // harness started during its start (its MCP servers) with it, as the utility clamp did.
        let tier = crate::qos::enabled() && imp::to_agent_tier(pid);
        match self {
            Self::Background => imp::set_background(pid, true) || tier,
            Self::Normal => tier,
        }
    }
}

/// The class a session's harness takes at its exec: its starter's, without a background class it
/// would inherit (macOS; elsewhere `cmd` is unchanged). Every harness start uses it: each has a
/// deadline (module docs, item 1).
pub fn start_at_normal(cmd: &mut tokio::process::Command) {
    #[cfg(target_os = "macos")]
    // SAFETY: the hook runs in the child between fork and exec and makes one setpriority(2) call
    // on itself: no allocation, no lock, async-signal-safe. It never fails the spawn: a harness
    // whose class could not be cleared starts as before.
    unsafe {
        cmd.pre_exec(|| {
            libc::setpriority(libc::PRIO_DARWIN_PROCESS, 0, 0);
            Ok(())
        });
    }
    #[cfg(not(target_os = "macos"))]
    let _ = cmd;
}

/// Clears a background class that another process set on the harness `pid` or on its starter
/// (macOS; elsewhere nothing), right after its spawn (module docs, item 1): its own clear at its
/// exec ([`start_at_normal`]) cannot clear that one. The same caution as [`CpuClass::enter`]
/// applies to `pid`. True when the call succeeded.
pub fn clear_running(pid: u32) -> bool {
    imp::set_background(pid, false)
}

/// What a harness was doing when its start missed its deadline or failed, read from the kernel
/// with no process listing (`proc_pidinfo` or `/proc/<pid>/stat` for the one pid).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HarnessState {
    pub pid: u32,
    /// Its scheduler base priority: 4 at background class, 20 under the agent hosts' utility
    /// clamp (`qos.rs`), 31 at the default.
    pub priority: i32,
    /// At background class (`PRIO_DARWIN_BG`, whatever set it): priority 4 or lower.
    pub background: bool,
    /// Seconds since it started.
    pub ran_secs: u64,
    /// CPU time it used, user and system, in milliseconds.
    pub cpu_ms: u64,
    pub threads: i32,
    /// Its threads on a CPU or ready for one when read: 0 while every thread waits (on the disk,
    /// memory, a lock or input).
    pub threads_running: i32,
    /// Its processes: the harness and those it started (a launcher's agent, its MCP servers).
    /// CPU time, threads and page-ins are the sums over them.
    pub processes: i32,
    /// Pages it read in from disk or swap: the work a harness does while memory is short and
    /// every thread waits on a page.
    pub pageins: u64,
    /// Its own program name (`sr2`, `claude`), so an error says which process it read.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub name: String,
    /// The earliest-started process it still has, if any: for a launcher (`sr2 claude`) usually
    /// its agent. An error names it, so a start that stalled before the launcher started its agent
    /// reads apart from one whose agent is slow (#36028: the stall was in `claude`, after `sr2`
    /// started it).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_child: Option<ChildSeen>,
}

/// The first process a harness started, as a start's deadline error names it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChildSeen {
    pub pid: u32,
    pub name: String,
    pub cpu_ms: u64,
    pub pageins: u64,
}

/// The CPU time a harness must use in a [`WORK_WINDOW`] to count as working: an idle launcher's
/// runtime spends some on its own. An `sr2` waiting on a stopped `claude` used 0.6 ms per 10 s
/// (2026-11-05, #36028), so "any change" kept a harness that did nothing counted as working and its
/// start never ended. A harness short of memory still reads pages in, and one short of CPU has a
/// thread ready, so neither needs this budget to count as working.
pub const WORK_CPU_MS: u64 = 5;

/// The span [`WORK_CPU_MS`] is measured over. A reader that reads more often keeps its older read
/// until this much time has passed (`HarnessState::worked_since`), so the bar is a rate, the same
/// at any tick.
pub const WORK_WINDOW: std::time::Duration = std::time::Duration::from_secs(10);

impl HarnessState {
    /// Whether it did any work in the `between` since `earlier`: a thread on a CPU, a page read
    /// in, a process started or ended, or [`WORK_CPU_MS`] of CPU time per [`WORK_WINDOW`] (never
    /// less than one window's worth, so a read sooner than a window asks for the whole budget). A
    /// loaded host or short memory slows that down; only a harness that waits on input or a lock
    /// does none of it.
    pub fn worked_since(&self, earlier: &HarnessState, between: std::time::Duration) -> bool {
        let windows = between.max(WORK_WINDOW).as_millis() as f64 / WORK_WINDOW.as_millis() as f64;
        self.threads_running > 0
            || self.cpu_ms.abs_diff(earlier.cpu_ms) as f64 >= WORK_CPU_MS as f64 * windows
            || self.pageins != earlier.pageins
            || self.processes != earlier.processes
    }
}

/// The state of the running process `pid` (macOS; elsewhere None). None once it ended or when the
/// kernel refuses (another user's process).
pub fn harness_state(pid: u32) -> Option<HarnessState> {
    imp::state(pid)
}

/// A portable progress signal for a live harness. On Linux this is the process's
/// cumulative user plus system CPU ticks from `/proc/<pid>/stat`; macOS reuses
/// its kernel CPU accounting. Platforms without a per-process signal return None.
pub fn harness_cpu_ticks(pid: u32) -> Option<u64> {
    imp::cpu_ticks(pid)
}

/// What a start's deadline error can say about its harness.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HarnessSeen {
    /// The start had not spawned it yet.
    NotStarted,
    /// It ended.
    Ended,
    /// It runs, and its state cannot be read (the platform lacks accounting, or the kernel refused).
    Unread,
    Running(HarnessState),
}

impl HarnessSeen {
    /// Running at background class.
    pub fn background(&self) -> Option<&HarnessState> {
        match self {
            Self::Running(state) if state.background => Some(state),
            _ => None,
        }
    }

    /// The clause a start's deadline error ends with (`agent_start`, the pool's start): what its
    /// harness was doing. Empty when that is not known.
    pub fn detail(&self) -> String {
        match self {
            Self::NotStarted => "; its agent process had not started".to_owned(),
            Self::Ended => "; its agent process is not running".to_owned(),
            Self::Unread => String::new(),
            Self::Running(state) => format!("; {state}"),
        }
    }
}

impl HarnessState {
    /// The class's name for people: "background" or "normal".
    pub fn class(&self) -> &'static str {
        if self.background { "background" } else { "normal" }
    }
}

impl std::fmt::Display for HarnessState {
    /// One clause for an error a person reads (no vendor names).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let named = if self.name.is_empty() { String::new() } else { format!(", {}", self.name) };
        write!(
            f,
            "its agent process (pid {}{named}, {} process{} in all) is alive at {} CPU class (priority {}), ran {} s, used {:.1} s of CPU, {} of {} threads running, {} page-ins",
            self.pid,
            self.processes,
            if self.processes == 1 { "" } else { "es" },
            self.class(),
            self.priority,
            self.ran_secs,
            self.cpu_ms as f64 / 1000.0,
            self.threads_running,
            self.threads,
            self.pageins,
        )?;
        // Only when it was read: an empty name means the platform names no process.
        if self.name.is_empty() {
            return Ok(());
        }
        match &self.first_child {
            Some(child) => write!(
                f,
                "; the first process it started is {} (pid {}), which used {:.1} s of CPU and {} page-ins",
                child.name,
                child.pid,
                child.cpu_ms as f64 / 1000.0,
                child.pageins,
            ),
            None => write!(f, "; it has started no process"),
        }
    }
}

/// Every process of the harness `pid`'s process group (it leads one: `agent_host/host.rs`,
/// `agent/command.rs`), so the harness, the processes it started during its start (its MCP
/// servers, a launcher's agent) and on Linux every thread of each, at [`crate::qos::AGENT_NICE`],
/// in one call and with no process listed. Processes they start later inherit it. Never raises
/// one: a group already at or past it is left, and an unprivileged process cannot lower a nice.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn lower_group(pid: u32) -> bool {
    // `id_t` is the pid's own width on both platforms.
    let group: libc::id_t = pid;
    if group == 0 {
        return false;
    }
    // `getpriority` answers -1 both for nice -1 and for an error: errno says which.
    #[cfg(target_os = "macos")]
    // SAFETY: the calling thread's errno.
    let errno = || unsafe { libc::__error() };
    #[cfg(target_os = "linux")]
    // SAFETY: the calling thread's errno.
    let errno = || unsafe { libc::__errno_location() };
    // SAFETY: plain syscalls on a group its caller holds the leader of; the kernel checks that
    // each process runs as this user. `PRIO_PGRP`'s get answers the group's lowest nice.
    unsafe {
        *errno() = 0;
        let now = libc::getpriority(libc::PRIO_PGRP, group);
        if *errno() != 0 {
            return false;
        }
        now >= crate::qos::AGENT_NICE
            || libc::setpriority(libc::PRIO_PGRP, group, crate::qos::AGENT_NICE) == 0
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::HarnessState;

    pub(super) fn to_agent_tier(pid: u32) -> bool {
        super::lower_group(pid)
    }

    /// `PRIO_DARWIN_BG` on (`on`) or off for the process `pid`, another process of this user.
    pub(super) fn set_background(pid: u32, on: bool) -> bool {
        // Never 0: that is the caller itself.
        let id: libc::id_t = pid;
        if id == 0 {
            return false;
        }
        let value = if on { libc::PRIO_DARWIN_BG } else { 0 };
        // SAFETY: plain syscall; the kernel checks that `pid` runs as this user.
        let set = unsafe { libc::setpriority(libc::PRIO_DARWIN_PROCESS, id, value) } == 0;
        if !set {
            tracing::debug!(
                pid,
                on,
                "setpriority(PRIO_DARWIN_PROCESS) failed: {}",
                std::io::Error::last_os_error()
            );
        }
        set
    }

    /// `proc_pidinfo(pid, flavor)` into a `T`, or None.
    fn pidinfo<T>(pid: libc::c_int, flavor: libc::c_int) -> Option<T> {
        let mut out = std::mem::MaybeUninit::<T>::zeroed();
        let size = libc::c_int::try_from(std::mem::size_of::<T>()).ok()?;
        // SAFETY: the buffer is `size` bytes of a `T`, which the kernel fills for this flavor.
        let n = unsafe { libc::proc_pidinfo(pid, flavor, 0, out.as_mut_ptr().cast(), size) };
        // SAFETY: the kernel wrote all `size` bytes (a short answer is refused above).
        (n == size).then(|| unsafe { out.assume_init() })
    }

    /// The most processes of one harness's tree it reads: a launcher, its agent and their MCP
    /// servers are a handful; the bound keeps a harness that forks a build from costing more.
    const TREE_MAX: usize = 64;

    /// The processes `root` started, and theirs, at most [`TREE_MAX`] in all with `root`, each
    /// with the process that started it (`root`'s own is 0). Only the descendants of a harness
    /// acpmux spawned and holds: no other process is listed.
    fn tree(root: libc::c_int) -> Vec<(libc::c_int, libc::c_int)> {
        let mut all = vec![(root, 0)];
        let mut next = 0;
        while next < all.len() && all.len() < TREE_MAX {
            let parent = all[next].0;
            let mut kids = [0 as libc::c_int; TREE_MAX];
            let bytes = libc::c_int::try_from(std::mem::size_of_val(&kids)).unwrap_or(0);
            // SAFETY: the buffer holds `bytes` bytes of pids, which the kernel fills.
            let n = unsafe { libc::proc_listchildpids(parent, kids.as_mut_ptr().cast(), bytes) };
            let n = usize::try_from(n).unwrap_or(0).min(TREE_MAX);
            for kid in kids[..n].iter().copied() {
                if all.len() == TREE_MAX {
                    break;
                }
                if kid > 0 && !all.iter().any(|(p, _)| *p == kid) {
                    all.push((kid, parent));
                }
            }
            next += 1;
        }
        all
    }

    // The Mach timebase's struct and call are deprecated in favour of the `mach2` crate, which
    // acpmux does not depend on; they are not defective.
    #[allow(deprecated)]
    pub(super) fn state(pid: u32) -> Option<HarnessState> {
        let id = libc::c_int::try_from(pid).ok().filter(|p| *p > 0)?;
        let task: libc::proc_taskinfo = pidinfo(id, libc::PROC_PIDTASKINFO)?;
        let bsd: libc::proc_bsdinfo = pidinfo(id, libc::PROC_PIDTBSDINFO)?;
        // The task's CPU times are in Mach time units (nanoseconds only on Intel).
        let mut base = libc::mach_timebase_info { numer: 1, denom: 1 };
        // SAFETY: the call fills the struct it is given.
        let ok = unsafe { libc::mach_timebase_info(&mut base) } == 0;
        let (numer, denom) = if ok && base.denom != 0 {
            (u128::from(base.numer), u128::from(base.denom))
        } else {
            (1, 1)
        };
        let (mut ticks, mut threads, mut running, mut pageins, mut processes) =
            (0u128, 0i32, 0i32, 0u64, 0i32);
        let to_ms = |ticks: u128| {
            u64::try_from(ticks.saturating_mul(numer) / denom / 1_000_000).unwrap_or(u64::MAX)
        };
        // The harness itself, then each process under it that is still there to read.
        let kids: Vec<(libc::c_int, libc::c_int, libc::proc_taskinfo)> = tree(id)
            .into_iter()
            .skip(1)
            .filter_map(|(kid, parent)| Some((kid, parent, pidinfo(kid, libc::PROC_PIDTASKINFO)?)))
            .collect();
        // Its first process: of those it started itself, the one that started first.
        let first_child = kids
            .iter()
            .filter(|(_, parent, _)| *parent == id)
            .filter_map(|(kid, _, t)| {
                let b: libc::proc_bsdinfo = pidinfo(*kid, libc::PROC_PIDTBSDINFO)?;
                Some(((b.pbi_start_tvsec, b.pbi_start_tvusec), *kid, name_of(&b), t))
            })
            .min_by_key(|(started, kid, _, _)| (*started, *kid))
            .map(|(_, kid, name, t)| super::ChildSeen {
                pid: u32::try_from(kid).unwrap_or(0),
                name,
                cpu_ms: to_ms(u128::from(t.pti_total_user.saturating_add(t.pti_total_system))),
                pageins: u64::try_from(t.pti_pageins).unwrap_or(0),
            });
        let rest = kids.iter().map(|(_, _, t)| *t);
        for t in std::iter::once(task).chain(rest) {
            ticks += u128::from(t.pti_total_user.saturating_add(t.pti_total_system));
            threads = threads.saturating_add(t.pti_threadnum);
            running = running.saturating_add(t.pti_numrunning);
            pageins = pageins.saturating_add(u64::try_from(t.pti_pageins).unwrap_or(0));
            processes += 1;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        Some(HarnessState {
            pid,
            priority: task.pti_priority,
            // MAXPRI_THROTTLE: the base priority of a darwinbg task.
            background: task.pti_priority <= 4,
            ran_secs: now.saturating_sub(bsd.pbi_start_tvsec),
            cpu_ms: to_ms(ticks),
            threads,
            threads_running: running,
            processes,
            pageins,
            name: name_of(&bsd),
            first_child,
        })
    }

    /// A process's program name: its long name, else its short one (both NUL-ended).
    fn name_of(bsd: &libc::proc_bsdinfo) -> String {
        let text = |chars: &[libc::c_char]| {
            let bytes: Vec<u8> =
                chars.iter().take_while(|c| **c != 0).map(|c| c.to_ne_bytes()[0]).collect();
            String::from_utf8_lossy(&bytes).into_owned()
        };
        let long = text(&bsd.pbi_name);
        if long.is_empty() { text(&bsd.pbi_comm) } else { long }
    }

    pub(super) fn cpu_ticks(pid: u32) -> Option<u64> {
        state(pid).map(|state| state.cpu_ms)
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use super::HarnessState;

    pub(super) fn set_background(_pid: u32, _on: bool) -> bool {
        false
    }

    /// The harness's process group at [`crate::qos::AGENT_NICE`] ([`super::lower_group`]), and
    /// the session it runs in (its agent host's, which leads one: `agent_host/link.rs`) at the same
    /// nice. Where the scheduler groups processes by session (autogroup, a process outside a CPU
    /// cgroup), a session's share against the rest of the machine is its group's nice, not its
    /// processes', so the group is lowered too. Never the daemon's own session (a harness it
    /// started directly).
    pub(super) fn to_agent_tier(pid: u32) -> bool {
        let lowered = super::lower_group(pid);
        let Ok(target) = libc::pid_t::try_from(pid) else { return lowered };
        // SAFETY: getsid reads; a pid that is gone answers -1.
        let (theirs, ours) = unsafe { (libc::getsid(target), libc::getsid(0)) };
        if lowered && theirs > 0 && theirs != ours {
            lower_autogroup(pid);
        }
        lowered
    }

    /// `/proc/<pid>/autogroup` at [`crate::qos::AGENT_NICE`], when the kernel has it and it is
    /// lower: absent without `CONFIG_SCHED_AUTOGROUP`, and a no-op for a process in a CPU cgroup.
    /// The kernel takes an unprivileged change at most every 100 ms across the machine (`EAGAIN`):
    /// a start that lands in another's 100 ms keeps its group's nice, and its harness's own.
    fn lower_autogroup(pid: u32) {
        let path = format!("/proc/{pid}/autogroup");
        // "/autogroup-123 nice 0"
        let now = std::fs::read_to_string(&path).ok().and_then(|text| {
            text.split_whitespace().last().and_then(|nice| nice.parse::<libc::c_int>().ok())
        });
        if now.is_none_or(|nice| nice >= crate::qos::AGENT_NICE) {
            return;
        }
        if let Err(e) = std::fs::write(&path, crate::qos::AGENT_NICE.to_string()) {
            tracing::debug!(pid, "lowering {path}: {e}");
        }
    }

    /// The one process record's fields after the parenthesized command name.
    /// The command may contain spaces, so split only after its final `)`.
    fn stat(pid: u32) -> Option<Vec<String>> {
        let raw = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let (_, fields) = raw.rsplit_once(')')?;
        Some(fields.split_whitespace().map(str::to_owned).collect())
    }

    /// `/proc/<pid>/stat` fields 14 and 15 (`utime` and `stime`) become indexes
    /// 11 and 12 after the leading pid and command name have been removed.
    fn ticks(pid: u32) -> Option<u64> {
        let fields = stat(pid)?;
        let user = fields.get(11)?.parse::<u64>().ok()?;
        let system = fields.get(12)?.parse::<u64>().ok()?;
        Some(user.saturating_add(system))
    }

    pub(super) fn cpu_ticks(pid: u32) -> Option<u64> {
        ticks(pid)
    }

    pub(super) fn state(_pid: u32) -> Option<HarnessState> {
        None
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod imp {
    use super::HarnessState;

    pub(super) fn set_background(_pid: u32, _on: bool) -> bool {
        false
    }

    pub(super) fn to_agent_tier(_pid: u32) -> bool {
        false
    }

    pub(super) fn state(_pid: u32) -> Option<HarnessState> {
        None
    }

    pub(super) fn cpu_ticks(_pid: u32) -> Option<u64> {
        None
    }
}

#[cfg(test)]
mod tests;
