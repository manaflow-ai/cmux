//! The CPU class a session's harness starts at (macOS). Agent harnesses and the tools they run
//! (builds, tests) otherwise compete with cmux and its Chromium renderers at the same priority,
//! and a busy Mac makes a dragged pane's page trail it (cmuxterm-hq#4947: p95 55 ms with 14 busy
//! processes at the default class, 6 ms with the same load at background class).
//!
//! `background` (the default) starts the harness with `PRIO_DARWIN_BG`, as cmux-git starts its
//! git children (`cmux-git` `run.rs`): the lowest CPU priority, throttled disk I/O and
//! background-class new sockets. It is set in the harness process between fork and exec, so the
//! harness and every process it starts afterwards inherit it; a running process is never
//! reniced. `normal` leaves the harness at the daemon's class.
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

/// The CPU class a session's harness starts at.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CpuClass {
    /// The daemon's own class: nothing changes at spawn.
    #[default]
    Normal,
    /// `PRIO_DARWIN_BG` on macOS.
    Background,
}

/// The class a session starts at when nothing names one.
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

    /// Starts `cmd`'s process at this class (macOS; elsewhere `cmd` is unchanged).
    pub fn apply(self, cmd: &mut tokio::process::Command) {
        #[cfg(target_os = "macos")]
        if self == Self::Background {
            // SAFETY: the hook runs in the child between fork and exec and makes one
            // setpriority(2) call on itself: no allocation, no lock, async-signal-safe. It never
            // fails the spawn: a harness that could not be lowered runs as before.
            unsafe {
                cmd.pre_exec(|| {
                    // <sys/resource.h>: PRIO_DARWIN_PROCESS and PRIO_DARWIN_BG.
                    const PRIO_DARWIN_PROCESS: libc::c_int = 4;
                    const PRIO_DARWIN_BG: libc::c_int = 0x1000;
                    libc::setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG);
                    Ok(())
                });
            }
        }
        #[cfg(not(target_os = "macos"))]
        let _ = cmd;
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
