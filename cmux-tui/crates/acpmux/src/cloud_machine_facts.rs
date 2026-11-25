//! What an agent on a cmux Cloud machine is told about that machine, beyond where it runs
//! (`cloud_repo_mcp::INSTRUCTIONS`): its size (CPUs, memory, disk) and the capabilities it has
//! there that it would not find on its own: the shared compiler cache (`sccache_env.rs`) and
//! working sub-sessions on forks of the machine (`placement/sub_fork.rs`, with AutoCloud on).
//!
//! Leo, 2026-11-25: "should we put a bit of a readme type note or anything at all on... like the
//! capabilities of the machine the agent it's on?" and "oh right there's maybe other stuff like
//! letting agents know ab other capabilities...?" An agent that does not know the machine's
//! memory starts a build that needs more than it has.
//!
//! Read once per server start, at `initialize`: a few file reads and one `statvfs`. A fact that
//! cannot be read is left out, never guessed.

use std::path::Path;

/// What [`paragraph`] says, as read from this machine.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Facts {
    pub cpus: Option<usize>,
    pub memory_bytes: Option<u64>,
    pub disk_total_bytes: Option<u64>,
    pub disk_free_bytes: Option<u64>,
    /// Rust builds here go through the shared compiler cache (`sccache_env::ENV_FILE` exists).
    pub compiler_cache: bool,
    /// A working sub-session runs on a fork of this machine (AutoCloud on, a Cloud machine id).
    pub sub_session_forks: bool,
}

impl Facts {
    /// This machine's facts: the disk of `home` (the work user's files).
    pub fn read(home: &Path) -> Self {
        let (disk_total_bytes, disk_free_bytes) = disk_of(home).unzip();
        Facts {
            cpus: std::thread::available_parallelism().ok().map(usize::from),
            memory_bytes: std::fs::read_to_string("/proc/meminfo")
                .ok()
                .and_then(|text| mem_total(&text)),
            disk_total_bytes,
            disk_free_bytes,
            compiler_cache: Path::new(crate::sccache_env::ENV_FILE).exists(),
            sub_session_forks: crate::placement::sub_fork::enabled()
                && crate::placement::sub_fork::this_machine().is_some(),
        }
    }
}

/// `MemTotal` of a `/proc/meminfo` text, in bytes.
pub fn mem_total(meminfo: &str) -> Option<u64> {
    let line = meminfo.lines().find(|l| l.starts_with("MemTotal:"))?;
    let mut words = line.split_whitespace().skip(1);
    let n: u64 = words.next()?.parse().ok()?;
    match words.next() {
        Some("kB") | None => n.checked_mul(1024),
        _ => None,
    }
}

/// Total and free (available to this user) bytes of the file system holding `path`.
#[cfg(unix)]
fn disk_of(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is a NUL-terminated path and `stat` a valid out pointer for the call.
    if unsafe { libc::statvfs(c.as_ptr(), &mut stat) } != 0 {
        return None;
    }
    let unit = stat.f_frsize as u64;
    Some(((stat.f_blocks as u64).saturating_mul(unit), (stat.f_bavail as u64).saturating_mul(unit)))
}

#[cfg(not(unix))]
fn disk_of(_: &Path) -> Option<(u64, u64)> {
    None
}

/// Bytes as whole GB (1 decimal under 10 GB), as `df -h` rounds.
fn gb(bytes: u64) -> String {
    let g = bytes as f64 / 1_000_000_000.0;
    if g < 10.0 { format!("{g:.1} GB") } else { format!("{g:.0} GB") }
}

/// The note for the agent: the machine's size, what to do with it, and the other capabilities it
/// has here. Empty when nothing could be read.
pub fn paragraph(f: &Facts) -> String {
    let mut size = Vec::new();
    if let Some(n) = f.cpus {
        size.push(format!("{n} CPU{}", if n == 1 { "" } else { "s" }));
    }
    if let Some(m) = f.memory_bytes {
        size.push(format!("{} of memory", gb(m)));
    }
    match (f.disk_total_bytes, f.disk_free_bytes) {
        (Some(t), Some(free)) => {
            size.push(format!("{} of disk ({} free when this chat started)", gb(t), gb(free)))
        }
        (Some(t), None) => size.push(format!("{} of disk", gb(t))),
        _ => {}
    }
    let mut out = Vec::new();
    if !size.is_empty() {
        out.push(format!(
            "This machine has {}. Size work to it: a build, install or test run that needs more \
memory or disk than this gets killed or fails part way, so run fewer parallel jobs (cargo -j, \
make -j, test workers) or a smaller target instead; `nproc`, `free -h` and `df -h` read the \
current numbers.",
            size.join(", ")
        ));
    }
    if f.compiler_cache {
        out.push(
            "Rust builds here go through a shared compiler cache (sccache, already set in the \
environment), so code built before compiles again quickly; leave RUSTC_WRAPPER as it is."
                .to_owned(),
        );
    }
    if f.sub_session_forks {
        out.push(
            "A working sub-session you start (start_session with worktree: true) runs on its own \
fork of this machine, with the same files, dependencies and caches, and its changes come back to \
this checkout as a patch: heavy or parallel work can go there instead of sharing this machine."
                .to_owned(),
        );
    }
    out.join(" ")
}

#[cfg(test)]
#[path = "cloud_machine_facts_tests.rs"]
mod tests;
