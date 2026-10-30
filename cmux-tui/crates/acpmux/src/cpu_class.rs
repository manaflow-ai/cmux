//! The CPU class a session's harness starts at (macOS). Agent harnesses and the tools they run
//! (builds, tests) otherwise compete with cmux and its Chromium renderers at the same priority,
//! and a busy Mac makes a dragged pane's page trail it (cmuxterm-hq#4947: p95 55 ms with 14 busy
//! processes at the default class, 6 ms with the same load at background class).
//!
//! `background` (the default) starts the harness under the posix_spawn QoS clamp at background
//! (`posix_spawnattr_set_qos_clamp_np`, the call behind `taskpolicy -c background` and the one
//! `qos.rs` uses for agent hosts): the lowest CPU priority and throttled disk I/O for the harness
//! and every process it starts afterwards; a running process is never reniced. The clamp is set
//! as the harness is exec'd ([`ClampedExec`]), so the exec itself runs at the starter's class.
//! It replaced `PRIO_DARWIN_BG` set before the exec (P-AUSTIN B10): that made the exec itself
//! run throttled, and on a busy Mac 25 harness spawns took p50 14 s (CPU load) and 28 s (CPU and
//! disk), against 1 to 13 ms under the clamp; an agent host answers its controller only after its
//! harness's spawn, so a wave of chats failed. `normal` leaves the harness at the daemon's class.
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
    /// macOS: the posix_spawn QoS clamp at background, set at the harness's exec (the harness and
    /// everything it starts at background priority); `PRIO_DARWIN_BG` only where this macOS has
    /// no clamp setter.
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

    /// Starts `cmd`'s process at this class (macOS; elsewhere `cmd` is unchanged). `env` is the
    /// complete environment `cmd` starts its process with. Call it last before the spawn: its
    /// hook execs the program itself, so no hook added after it runs.
    pub fn apply(self, cmd: &mut tokio::process::Command, env: &[(String, String)]) {
        #[cfg(target_os = "macos")]
        if self == Self::Background {
            match ClampedExec::new(cmd.as_std(), env) {
                // SAFETY: the hook runs in the forked child of a multithreaded process, where
                // std would call execvp next; it calls posix_spawn with SETEXEC in its place,
                // every argument built before the fork. Apple does NOT document posix_spawn as
                // async-signal-safe, so this rests on its implementation, not on a contract. Read
                // in xnu libsyscall/wrappers/spawn/posix_spawn.c (apple-oss-distributions/xnu
                // main, 2026-10-30): it fills a descriptor on the stack, reads only attribute
                // pointers ours leaves NULL, consults `posix_spawn_with_filter` ("always NULL on
                // customer installs"), then makes the __posix_spawn syscall: no allocation, no
                // lock, as its execve wrapper (same filter check), which std calls here anyway.
                // Accepted because the alternative, a posix_spawn in the parent, loses the cwd
                // pin check and tokio's `Child` (#28442). It returns only the call's error.
                Some(exec) => unsafe {
                    cmd.pre_exec(move || Err(exec.exec()));
                },
                // No clamp setter on this macOS (every supported macOS has it): the harness is
                // lowered as before, with its exec throttled.
                // SAFETY: one setpriority(2) call on itself: async-signal-safe.
                None => unsafe {
                    note_no_clamp();
                    cmd.pre_exec(|| {
                        libc::setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG);
                        Ok(())
                    });
                },
            };
        }
        #[cfg(not(target_os = "macos"))]
        let _ = (cmd, env);
    }
}

/// <sys/resource.h>: `PRIO_DARWIN_PROCESS` and `PRIO_DARWIN_BG`.
#[cfg(target_os = "macos")]
const PRIO_DARWIN_PROCESS: libc::c_int = 4;
#[cfg(target_os = "macos")]
const PRIO_DARWIN_BG: libc::c_int = 0x1000;
/// `POSIX_SPAWN_PROC_CLAMP_BACKGROUND` (spawn_private.h): the clamp's own number for background.
#[cfg(target_os = "macos")]
const CLAMP_BACKGROUND: u64 = 2;
#[cfg(target_os = "macos")]
use crate::qos::POSIX_SPAWN_SETEXEC;

/// Says once that harnesses start darwinbg, their exec throttled (no clamp setter here).
#[cfg(target_os = "macos")]
fn note_no_clamp() {
    static NOTED: std::sync::Once = std::sync::Once::new();
    NOTED.call_once(|| {
        tracing::warn!(
            "no posix_spawn QoS clamp on this macOS: background harnesses start darwinbg, their \
             exec throttled"
        );
    });
}

/// The harness's exec under the background clamp, built before the fork: a posix_spawn with
/// `POSIX_SPAWN_SETEXEC` (same pid, descriptors, process group and folder, as the execvp it takes
/// the place of) of the resolved program, its arguments and its complete environment. A file the
/// kernel cannot exec (ENOEXEC: a script with no `#!`) runs with /bin/sh, as execvp runs it.
#[cfg(target_os = "macos")]
struct ClampedExec {
    /// None: no such program on the harness's PATH; the exec fails with ENOENT, as execvp would.
    path: Option<std::ffi::CString>,
    _argv: Vec<std::ffi::CString>,
    _envp: Vec<std::ffi::CString>,
    argv_ptrs: Vec<*mut libc::c_char>,
    envp_ptrs: Vec<*mut libc::c_char>,
    /// `sh <path> <args…>` for ENOEXEC (its strings: `_sh_argv`).
    _sh_argv: Vec<std::ffi::CString>,
    sh_argv_ptrs: Vec<*mut libc::c_char>,
    attr: libc::posix_spawnattr_t,
}

// SAFETY: the raw pointers point into the CStrings this value owns and into its spawn attribute,
// which nothing but `exec` reads (in the forked child) and `drop` frees.
#[cfg(target_os = "macos")]
unsafe impl Send for ClampedExec {}
// SAFETY: as for Send; `exec` only reads.
#[cfg(target_os = "macos")]
unsafe impl Sync for ClampedExec {}

#[cfg(target_os = "macos")]
impl ClampedExec {
    /// None when this macOS has no clamp setter, an argument holds a NUL, or the attribute
    /// cannot be made.
    fn new(cmd: &std::process::Command, env: &[(String, String)]) -> Option<Self> {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let set_clamp = crate::qos::clamp_setter()?;
        let program = cmd.get_program();
        let path = resolve(program, env, cmd.get_current_dir())?;
        let argv: Vec<CString> = std::iter::once(program)
            .chain(cmd.get_args())
            .map(|a| CString::new(a.as_bytes()).ok())
            .collect::<Option<_>>()?;
        let envp: Vec<CString> = env
            .iter()
            .map(|(k, v)| CString::new(format!("{k}={v}")).ok())
            .collect::<Option<_>>()?;
        let ptrs = |v: &[CString]| -> Vec<*mut libc::c_char> {
            v.iter().map(|a| a.as_ptr().cast_mut()).chain([std::ptr::null_mut()]).collect()
        };
        let (argv_ptrs, envp_ptrs) = (ptrs(&argv), ptrs(&envp));
        let sh_argv: Vec<CString> = match &path {
            Some(path) => [c"sh".to_owned(), path.clone()]
                .into_iter()
                .chain(argv.iter().skip(1).cloned())
                .collect(),
            None => Vec::new(),
        };
        let sh_argv_ptrs = ptrs(&sh_argv);
        let mut attr: libc::posix_spawnattr_t = std::ptr::null_mut();
        // SAFETY: initializes `attr`, which `drop` destroys; the setters take the initialized
        // attribute and constants.
        unsafe {
            if libc::posix_spawnattr_init(&mut attr) != 0 {
                return None;
            }
            if set_clamp(&mut attr, CLAMP_BACKGROUND) != 0
                || libc::posix_spawnattr_setflags(&mut attr, POSIX_SPAWN_SETEXEC) != 0
            {
                libc::posix_spawnattr_destroy(&mut attr);
                return None;
            }
        }
        Some(Self {
            path,
            _argv: argv,
            _envp: envp,
            argv_ptrs,
            envp_ptrs,
            _sh_argv: sh_argv,
            sh_argv_ptrs,
            attr,
        })
    }

    /// Replaces this (forked) process with the harness; returns only the error.
    fn exec(&self) -> std::io::Error {
        let Some(path) = &self.path else {
            return std::io::Error::from_raw_os_error(libc::ENOENT);
        };
        let mut rc = self.spawn(path.as_ptr(), &self.argv_ptrs);
        if rc == libc::ENOEXEC {
            rc = self.spawn(c"/bin/sh".as_ptr(), &self.sh_argv_ptrs);
        }
        std::io::Error::from_raw_os_error(if rc == 0 { libc::EINVAL } else { rc })
    }

    /// One posix_spawn in place of this process; its error code (it returns only on failure).
    fn spawn(&self, path: *const libc::c_char, argv: &[*mut libc::c_char]) -> libc::c_int {
        let mut pid: libc::pid_t = 0;
        // SAFETY: the path, vectors and attribute were built before the fork and are
        // NUL-terminated; with SETEXEC a successful call does not return.
        unsafe {
            libc::posix_spawn(
                &mut pid,
                path,
                std::ptr::null(),
                &self.attr,
                argv.as_ptr(),
                self.envp_ptrs.as_ptr(),
            )
        }
    }
}

#[cfg(target_os = "macos")]
impl Drop for ClampedExec {
    fn drop(&mut self) {
        // SAFETY: the attribute `new` initialized.
        unsafe { libc::posix_spawnattr_destroy(&mut self.attr) };
    }
}

/// The program path execvp would run for `program` with `env`'s PATH: `program` itself when it
/// names a path, else the first executable file of that name in the PATH's folders. A path
/// under a relative PATH folder stays relative: the child execs it from the folder it changed
/// into, after the cwd pin's check there (`cwd_pin.rs`), never through `cwd`'s name, which a
/// folder swapped after the check could redirect; `cwd` is only where the parent looks for it.
/// `Some(None)`: not found (the exec then fails with ENOENT, as execvp's would); None: a NUL in
/// it.
#[cfg(target_os = "macos")]
fn resolve(
    program: &std::ffi::OsStr,
    env: &[(String, String)],
    cwd: Option<&std::path::Path>,
) -> Option<Option<std::ffi::CString>> {
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::PermissionsExt;
    let cstring = |p: &std::path::Path| std::ffi::CString::new(p.as_os_str().as_bytes()).ok();
    if program.as_bytes().contains(&b'/') {
        return cstring(std::path::Path::new(program)).map(Some);
    }
    let path = env.iter().find(|(k, _)| k == "PATH").map_or("/usr/bin:/bin", |(_, v)| v.as_str());
    let found = std::env::split_paths(path).map(|dir| dir.join(program)).find(|candidate| {
        let seen = match cwd {
            Some(cwd) if candidate.is_relative() => cwd.join(candidate),
            _ => candidate.clone(),
        };
        std::fs::metadata(seen).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    });
    match found {
        Some(found) => cstring(&found).map(Some),
        None => Some(None),
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
