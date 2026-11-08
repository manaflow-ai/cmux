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
//! 1. The harness starts at its starter's class (an agent host's utility clamp, `qos.rs`, or the
//!    daemon's class) and keeps no background class it would inherit: between fork and exec it
//!    clears one set on its starter by the starter itself (an agent host under
//!    `ACPMUX_QOS=background`, [`start_at_normal`]), and right after the spawn the daemon clears
//!    one that another process set ([`clear_running`]; a process cannot clear that one itself).
//!    The exec and the harness's own start run at normal CPU class. Disk I/O stays at the
//!    starter's `IOPOL_UTILITY` (`qos.rs`): utility, not throttled.
//! 2. Once the session's start is over (its `initialize` and `session/new` or `session/load`
//!    answered, `hub/lifecycle.rs` `ensure_child`), the daemon puts the running harness in its
//!    class ([`CpuClass::enter`]): `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`, which
//!    macOS allows on another process of the same user. Every process the harness starts after
//!    that inherits it, so the builds and tests of its turns run below the GUI. A process it
//!    started during its start keeps the class it started at: an MCP server, and the real agent
//!    of a harness that is only a launcher (a script or adapter that starts the agent as a child
//!    and waits for it), whose turns then run at normal class. acpmux does not list processes
//!    (`scripts/cmux-next/check-no-process-scan.py`), so only the harness itself is reniced, once.
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
//! (`acpmux config --set session.cpu_class=normal`), then `background`. Linux sessions get their
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

/// The class a session runs at when nothing names one.
pub const DEFAULT: CpuClass = CpuClass::Background;

impl CpuClass {
    /// `normal` or `background` (any case, trimmed); None for anything else.
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "normal" => Some(Self::Normal),
            "background" => Some(Self::Background),
            _ => None,
        }
    }

    /// The class of a session whose harness gets the environment `harness_env` (the command's
    /// complete one: the profile's values resolved, the daemon's own `ACPMUX_*` removed), with the
    /// daemon's env and config read now (at each spawn, as the session scope's limits are).
    #[cfg(target_os = "macos")]
    pub fn for_session<'a>(harness_env: impl IntoIterator<Item = (&'a str, &'a str)>) -> Self {
        let profile = harness_env.into_iter().find(|(k, _)| *k == ENV).map(|(_, v)| v);
        let config = crate::config::Config::load().ok().and_then(|c| c.session.cpu_class);
        Self::resolve(profile, std::env::var(ENV).ok(), config)
    }

    /// Off macOS: `normal`, with nothing read.
    #[cfg(not(target_os = "macos"))]
    pub fn for_session<'a>(_harness_env: impl IntoIterator<Item = (&'a str, &'a str)>) -> Self {
        Self::Normal
    }

    /// The first valid of the profile's value, the daemon's env value and config's, else
    /// [`DEFAULT`]. A value that names no class is skipped, with a warning.
    pub fn resolve(profile: Option<&str>, daemon: Option<String>, config: Option<Self>) -> Self {
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
            .unwrap_or(DEFAULT)
    }

    /// Puts the running harness `pid` in this class (macOS; elsewhere nothing). Only
    /// `Background` changes it, and only lowers. `pid` must be a harness its caller holds (a direct
    /// child not reaped yet, or one its agent host reports alive): a pid that another process took
    /// would be lowered instead. True when the class was set.
    pub fn enter(self, pid: u32) -> bool {
        if self == Self::Normal {
            return false;
        }
        imp::set_background(pid, true)
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

#[cfg(target_os = "macos")]
mod imp {
    use super::HarnessState;

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

    pub(super) fn state(_pid: u32) -> Option<HarnessState> {
        None
    }

    pub(super) fn cpu_ticks(_pid: u32) -> Option<u64> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_valid_source_names_the_class_else_background() {
        let bg = Some(CpuClass::Background);
        assert_eq!(CpuClass::resolve(None, None, None), CpuClass::Background);
        assert_eq!(CpuClass::resolve(None, None, Some(CpuClass::Normal)), CpuClass::Normal);
        // The daemon's env overrides config; the profile overrides both.
        assert_eq!(CpuClass::resolve(None, Some("normal".into()), bg), CpuClass::Normal);
        assert_eq!(
            CpuClass::resolve(Some("background"), Some("normal".into()), Some(CpuClass::Normal)),
            CpuClass::Background
        );
        assert_eq!(CpuClass::resolve(Some(" Normal "), None, bg), CpuClass::Normal);
        // A value that names no class is skipped.
        assert_eq!(CpuClass::resolve(Some("utility"), Some("normal".into()), bg), CpuClass::Normal);
        assert_eq!(CpuClass::resolve(Some(""), None, None), CpuClass::Background);
    }

    /// The 2026-11-04 stall: `sr2 claude` waits on its `claude`, which does the work. A launcher
    /// that only waits must not read as a harness that does nothing.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_launchers_harness_state_counts_the_work_of_the_agent_it_started() {
        use std::io::BufRead;
        // The launcher (`sh`, kept by the `; :` after its one command) waits on its agent, which
        // spends CPU, says so, then waits on its input.
        let agent = "i=0; while [ $i -lt 100000 ]; do i=$((i+1)); done; echo worked; cat";
        let mut launcher = std::process::Command::new("/bin/sh")
            .args(["-c", &format!("/bin/sh -c '{agent}'; :")])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .expect("spawn the launcher");
        let mut said = String::new();
        let stdout = launcher.stdout.take().expect("its stdout");
        std::io::BufReader::new(stdout).read_line(&mut said).expect("the agent's line");
        assert_eq!(said.trim(), "worked");
        let state = harness_state(launcher.id()).expect("read the launcher");
        drop(launcher.stdin.take());
        let _ = launcher.kill();
        let _ = launcher.wait();
        // The launcher alone used a few ms; its agent's loop took far more.
        assert!(state.cpu_ms >= 100, "the agent's CPU time counts: {state:?}");
        // The error names the launcher and the agent it started, with the agent's own work.
        // Named by the kernel (macOS's `/bin/sh` runs as `bash`, so no fixed name is asserted).
        assert!(!state.name.is_empty(), "the launcher's name: {state:?}");
        let agent = state.first_child.as_ref().expect("the agent the launcher started");
        assert!(!agent.name.is_empty(), "the agent's name: {state:?}");
        assert_ne!(agent.pid, state.pid);
        assert!(agent.cpu_ms >= 50, "the agent's own CPU time: {state:?}");
        let said = state.to_string();
        let named =
            format!("; the first process it started is {} (pid {}), ", agent.name, agent.pid);
        assert!(said.contains(&named), "{said}");
    }

    /// #36028: a start's error says which process it read and what its launcher started, so a
    /// launcher that never started its agent reads apart from an agent that is slow.
    #[test]
    fn a_deadline_clause_names_the_launcher_and_the_agent_it_started() {
        let launcher = HarnessState {
            pid: 9104,
            priority: 20,
            background: false,
            ran_secs: 87,
            cpu_ms: 140,
            threads: 20,
            threads_running: 0,
            processes: 2,
            pageins: 1800,
            name: "sr2".to_owned(),
            first_child: Some(ChildSeen {
                pid: 9120,
                name: "claude".to_owned(),
                cpu_ms: 40,
                pageins: 1700,
            }),
        };
        assert_eq!(
            launcher.to_string(),
            "its agent process (pid 9104, sr2, 2 processes in all) is alive at normal CPU class \
             (priority 20), ran 87 s, used 0.1 s of CPU, 0 of 20 threads running, 1800 page-ins; \
             the first process it started is claude (pid 9120), which used 0.0 s of CPU and 1700 \
             page-ins"
        );
        let alone = HarnessState { first_child: None, processes: 1, ..launcher.clone() };
        assert!(alone.to_string().ends_with("; it has started no process"), "{alone}");
        // A platform that names no process adds nothing.
        let unnamed = HarnessState { name: String::new(), ..alone };
        assert!(unnamed.to_string().ends_with(" page-ins"), "{unnamed}");
    }

    #[test]
    fn a_page_in_or_a_process_change_is_work_and_waiting_alone_is_not() {
        let idle = HarnessState {
            pid: 1,
            priority: 31,
            background: false,
            ran_secs: 60,
            cpu_ms: 100,
            threads: 12,
            threads_running: 0,
            processes: 2,
            pageins: 500,
            name: String::new(),
            first_child: None,
        };
        let w = WORK_WINDOW;
        assert!(!idle.worked_since(&idle, w));
        assert!(HarnessState { pageins: 501, ..idle.clone() }.worked_since(&idle, w));
        assert!(HarnessState { processes: 3, ..idle.clone() }.worked_since(&idle, w));
        assert!(HarnessState { cpu_ms: 100 + WORK_CPU_MS, ..idle.clone() }.worked_since(&idle, w));
        // #36028: an idle launcher's runtime ticks (0.6 ms per 10 s for `sr2`) are not work.
        assert!(!HarnessState { cpu_ms: 101, ..idle.clone() }.worked_since(&idle, w));
        assert!(HarnessState { threads_running: 1, ..idle.clone() }.worked_since(&idle, w));
        // The bar is a rate: a read 1 s on asks for a whole window's budget, a read 30 s on (a
        // skipped tick) for three.
        let second = std::time::Duration::from_secs(1);
        assert!(!HarnessState { cpu_ms: 104, ..idle.clone() }.worked_since(&idle, second));
        assert!(HarnessState { cpu_ms: 105, ..idle.clone() }.worked_since(&idle, second));
        let late = std::time::Duration::from_secs(30);
        assert!(!HarnessState { cpu_ms: 114, ..idle.clone() }.worked_since(&idle, late));
        assert!(HarnessState { cpu_ms: 115, ..idle.clone() }.worked_since(&idle, late));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_harness_cpu_ticks_reads_one_process_record() {
        assert!(harness_cpu_ticks(std::process::id()).is_some());
    }
}
