//! The CPU class a session's harness runs at (macOS). Agent harnesses and the tools they run
//! (builds, tests) otherwise compete with cmux and its Chromium renderers at the same priority,
//! and a busy Mac makes a dragged pane's page trail it (cmuxterm-hq#4947: p95 55 ms with 14 busy
//! processes at the default class, 6 ms with the same load at background class).
//!
//! `background` (the default) puts the harness in `PRIO_DARWIN_BG`, as cmux-git starts its git
//! children (`cmux-git` `run.rs`): the lowest CPU priority, throttled disk I/O and
//! background-class new sockets. `normal` leaves the harness at its starter's class.
//!
//! The start never runs at background class. Every start has a deadline (`agent_start`, the
//! pool's `START_BUDGET`, the app's own wait on `session/new`), and a background harness can miss
//! it on a busy disk: on 2026-10-30 (load 125 on 18 cores, `du` and `git` scans of a 3.3 TB disk)
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
/// with no process listing (`proc_pidinfo` of the one pid).
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
    /// a lock or input).
    pub threads_running: i32,
}

/// The state of the running process `pid` (macOS; elsewhere None). None once it ended or when the
/// kernel refuses (another user's process).
pub fn harness_state(pid: u32) -> Option<HarnessState> {
    imp::state(pid)
}

/// What a start's deadline error can say about its harness.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HarnessSeen {
    /// The start had not spawned it yet.
    NotStarted,
    /// It ended.
    Ended,
    /// It runs, and its state cannot be read (not macOS, or the kernel refused).
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
        write!(
            f,
            "its agent process (pid {}) is alive at {} CPU class (priority {}), ran {} s, used {:.1} s of CPU, {} of {} threads running",
            self.pid,
            self.class(),
            self.priority,
            self.ran_secs,
            self.cpu_ms as f64 / 1000.0,
            self.threads_running,
            self.threads,
        )
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
        let cpu_ns = u128::from(task.pti_total_user.saturating_add(task.pti_total_system))
            .saturating_mul(numer)
            / denom;
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
            cpu_ms: u64::try_from(cpu_ns / 1_000_000).unwrap_or(u64::MAX),
            threads: task.pti_threadnum,
            threads_running: task.pti_numrunning,
        })
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::HarnessState;

    pub(super) fn set_background(_pid: u32, _on: bool) -> bool {
        false
    }

    pub(super) fn state(_pid: u32) -> Option<HarnessState> {
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
}
