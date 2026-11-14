//! The processes under a host, for ending the ones a harness moved out of
//! its process group (setsid): the group signal misses them, and once their
//! parent exits nothing links them to the host any more. A process is known
//! by pid and start time, so a pid reused after it ended is never signalled.

/// A process by pid and start time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Started {
    pub pid: u32,
    ppid: u32,
    start: String,
}

/// `ps -axww -o <fields>`: whether it exited 0, and what it printed. The one process listing in
/// acpmux's agent host code: ending what a harness left behind and the idle census.
fn ps(fields: &str) -> Option<(bool, Vec<u8>)> {
    let out = std::process::Command::new("ps").args(["-axww", "-o", fields]).output().ok()?;
    Some((out.status.success(), out.stdout))
}

/// Every process, from `ps`; empty when `ps` fails.
fn process_table() -> Vec<Started> {
    let Some((_, out)) = ps("pid=,ppid=,lstart=") else {
        return Vec::new();
    };
    String::from_utf8_lossy(&out)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let pid = fields.next()?.parse().ok()?;
            let ppid = fields.next()?.parse().ok()?;
            let start = fields.collect::<Vec<_>>().join(" ");
            (!start.is_empty()).then_some(Started { pid, ppid, start })
        })
        .collect()
}

/// The processes under `roots`, by parent. A root of 0 or 1, or this
/// process or one of its ancestors, is never taken: the caller must not end
/// itself or the system.
pub fn descendants(roots: &[u32]) -> Vec<Started> {
    let table = process_table();
    let spared = spared(&table);
    let own = std::process::id();
    let mut frontier: Vec<u32> =
        roots.iter().copied().filter(|r| *r == own || !spared.contains(r)).collect();
    let mut found: Vec<Started> = Vec::new();
    while let Some(parent) = frontier.pop() {
        for p in table.iter().filter(|p| p.ppid == parent && !spared.contains(&p.pid)) {
            if !found.iter().any(|f| f.pid == p.pid) {
                found.push(p.clone());
                frontier.push(p.pid);
            }
        }
    }
    found
}

/// The pids never taken: 0, 1, this process and its ancestors.
fn spared(table: &[Started]) -> Vec<u32> {
    let mut spared = vec![0, 1];
    let mut me = std::process::id();
    while me > 1 && !spared.contains(&me) {
        spared.push(me);
        me = table.iter().find(|p| p.pid == me).map_or(0, |p| p.ppid);
    }
    spared
}

/// The processes started with `name=value` in their environment, as the kernel has it: what a
/// host's harness and everything under it inherit (`HOST_MARK`), a setsid helper too, so they
/// are found after the parent link is gone. A process whose environment cannot be read (another
/// user's) is not taken, nor this process or its ancestors.
pub fn marked(name: &str, value: &str) -> Vec<Started> {
    let table = process_table();
    let spared = spared(&table);
    table
        .into_iter()
        .filter(|p| !spared.contains(&p.pid))
        .filter(|p| {
            environ(p.pid).is_some_and(|env| env.iter().any(|(k, v)| k == name && v == value))
        })
        .collect()
}

/// SIGKILL each of `procs` that still runs as the same process.
pub fn kill_still_running(procs: &[Started]) {
    signal_still_running(procs, libc::SIGKILL);
}

/// Send `signal` to each of `procs` that still runs as the same process (pid and start time).
pub fn signal_still_running(procs: &[Started], signal: libc::c_int) {
    if procs.is_empty() {
        return;
    }
    let table = process_table();
    for p in procs {
        if !table.iter().any(|now| now.pid == p.pid && now.start == p.start) {
            continue;
        }
        let Ok(pid) = i32::try_from(p.pid) else { continue };
        // SAFETY: the pid runs with the start time it had when `procs` was read.
        unsafe { libc::kill(pid, signal) };
    }
}

/// SIGTERM each of `procs` whose argv `pick` takes, if it still runs as the same process (pid
/// and start time); returns the pid and argv of each one signalled (`hub/silent_listing.rs`).
pub fn terminate_picked(
    procs: &[Started],
    pick: impl Fn(&[String]) -> bool,
) -> Vec<(u32, Vec<String>)> {
    let mut ended = Vec::new();
    for p in procs {
        let Some(args) = argv(p.pid).filter(|a| pick(a)) else { continue };
        let table = process_table();
        if !table.iter().any(|now| now.pid == p.pid && now.start == p.start) {
            continue;
        }
        let Ok(pid) = i32::try_from(p.pid) else { continue };
        // SAFETY: the pid runs with the start time it had when `procs` was read.
        if unsafe { libc::kill(pid, libc::SIGTERM) } == 0 {
            ended.push((p.pid, args));
        }
    }
    ended
}

/// A live process running under a harness, for the idle census (`hub/idle_census.rs`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Under {
    pub pid: u32,
    pub ppid: u32,
    /// Its command line as `ps` prints it (argv joined by spaces).
    pub args: String,
}

/// The exact argv of `pid`, word by word (`ps` joins it with spaces, so a word with a space in it,
/// such as a path into `/Applications/cmux NIGHTLY.app`, cannot be told apart there). `None` when
/// it cannot be read: the process ended, belongs to another user, or rewrote its argument area.
#[cfg(target_os = "macos")]
pub fn argv(pid: u32) -> Option<Vec<String>> {
    procargs2_argv(&procargs2(pid)?)
}

/// The raw `KERN_PROCARGS2` answer for `pid`: `argc`, the exec path, then argv and env.
#[cfg(target_os = "macos")]
fn procargs2(pid: u32) -> Option<Vec<u8>> {
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut argmax: libc::c_int = 0;
    let mut size = std::mem::size_of::<libc::c_int>();
    let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
    // SAFETY: the out buffer is a c_int and `size` is its size.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            2,
            (&raw mut argmax).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 || argmax <= 0 {
        return None;
    }
    let mut buffer = vec![0u8; argmax as usize];
    let mut filled = buffer.len();
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    // SAFETY: the buffer is writable for `filled` bytes, which is passed.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buffer.as_mut_ptr().cast(),
            &mut filled,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 {
        return None;
    }
    buffer.truncate(filled);
    Some(buffer)
}

/// The environment `pid` was started with, from `KERN_PROCARGS2` (after its argv); `None` when
/// it cannot be read (`environ`).
#[cfg(target_os = "macos")]
pub fn environ(pid: u32) -> Option<Vec<(String, String)>> {
    procargs2_env(&procargs2(pid)?)
}

/// The environment `pid` was started with (`/proc/<pid>/environ`): what its exec was given,
/// which a later `setenv` of its own does not change. `None` when it cannot be read: the process
/// ended or belongs to another user.
#[cfg(target_os = "linux")]
pub fn environ(pid: u32) -> Option<Vec<(String, String)>> {
    Some(env_pairs(&proc_file(pid, "environ")?))
}

/// Other unix systems: no environment is read.
#[cfg(all(unix, not(any(target_os = "macos", target_os = "linux"))))]
pub fn environ(_pid: u32) -> Option<Vec<(String, String)>> {
    None
}

/// The exact argv of `pid` from `/proc/<pid>/cmdline`; `None` when it cannot be read.
#[cfg(target_os = "linux")]
pub fn argv(pid: u32) -> Option<Vec<String>> {
    cmdline_argv(&proc_file(pid, "cmdline")?)
}

/// `/proc/<pid>/<file>` of the one process `pid`; `None` when it cannot be read.
#[cfg(target_os = "linux")]
fn proc_file(pid: u32, file: &str) -> Option<Vec<u8>> {
    std::fs::read(format!("/proc/{pid}/{file}")).ok()
}

/// Other unix systems: argv is not read, so no process passes for a server.
#[cfg(all(unix, not(any(target_os = "macos", target_os = "linux"))))]
pub fn argv(_pid: u32) -> Option<Vec<String>> {
    None
}

/// The executable `pid` runs, from the kernel (`proc_pidpath`), which the process cannot change
/// the way it can its argv. `None` when it cannot be read.
#[cfg(target_os = "macos")]
pub fn exe(pid: u32) -> Option<std::path::PathBuf> {
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let size = u32::try_from(buffer.len()).ok()?;
    // SAFETY: the buffer is writable for its whole length, which is passed.
    let written = unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), size) };
    match usize::try_from(written).ok().filter(|n| *n > 0) {
        Some(n) => {
            buffer.truncate(n);
            Some(std::path::PathBuf::from(String::from_utf8(buffer).ok()?))
        }
        // `proc_pidpath` fails once the file the process runs was replaced (an app update swaps
        // the bundle under every running MCP server). The exec path the kernel recorded at exec
        // is not argv (`exec -a` and `process.title` leave it), so it still names the program;
        // without it every server started before an update was "unknown" and its idle harness
        // never hibernated (160 hosts, 920 processes on one Mac).
        None => procargs2_exec_path(&procargs2(u32::try_from(pid).ok()?)?),
    }
}

/// The executable `pid` runs (`/proc/<pid>/exe`); `None` when it cannot be read.
#[cfg(target_os = "linux")]
pub fn exe(pid: u32) -> Option<std::path::PathBuf> {
    // A replaced file reads as `PATH (deleted)`: still the program the server was started as.
    std::fs::read_link(format!("/proc/{pid}/exe")).ok().map(crate::self_command::undeleted)
}

/// Other unix systems: no executable is read, so no process passes for a server.
#[cfg(all(unix, not(any(target_os = "macos", target_os = "linux"))))]
pub fn exe(_pid: u32) -> Option<std::path::PathBuf> {
    None
}

/// The folder `pid` runs in (`proc_pidinfo` `PROC_PIDVNODEPATHINFO`); `None` when it cannot be
/// read.
#[cfg(target_os = "macos")]
pub fn cwd(pid: u32) -> Option<std::path::PathBuf> {
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut info = std::mem::MaybeUninit::<libc::proc_vnodepathinfo>::zeroed();
    let size = libc::c_int::try_from(std::mem::size_of::<libc::proc_vnodepathinfo>()).ok()?;
    // SAFETY: the buffer is a zeroed `proc_vnodepathinfo` and `size` is its size.
    let written = unsafe {
        libc::proc_pidinfo(pid, libc::PROC_PIDVNODEPATHINFO, 0, info.as_mut_ptr().cast(), size)
    };
    if written != size {
        return None;
    }
    // SAFETY: zeroed plain data, which `proc_pidinfo` filled whole.
    let info = unsafe { info.assume_init() };
    let path: Vec<u8> = info
        .pvi_cdir
        .vip_path
        .iter()
        .flatten()
        .map(|c| c.to_ne_bytes()[0])
        .take_while(|b| *b != 0)
        .collect();
    let path = String::from_utf8(path).ok().filter(|p| p.starts_with('/'))?;
    Some(std::path::PathBuf::from(path))
}

/// The folder `pid` runs in (`/proc/<pid>/cwd`); `None` when it cannot be read.
#[cfg(target_os = "linux")]
pub fn cwd(pid: u32) -> Option<std::path::PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/cwd")).ok()
}

/// Other unix systems: no folder is read, so no relative script passes for a server.
#[cfg(all(unix, not(any(target_os = "macos", target_os = "linux"))))]
pub fn cwd(_pid: u32) -> Option<std::path::PathBuf> {
    None
}

/// What the idle census knows of a process to tell whether it is an MCP server: the executable
/// the kernel says it runs, its exact argv, and the folder it runs in (`None` when that cannot be
/// read: then no relative word of its argv names a file).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    pub exe: std::path::PathBuf,
    pub argv: Vec<String>,
    pub cwd: Option<std::path::PathBuf>,
}

/// [`exe`], [`argv`] and [`cwd`] of `pid`; `None` when the executable or argv cannot be read.
#[cfg(unix)]
pub fn identity(pid: u32) -> Option<Identity> {
    Some(Identity { exe: exe(pid)?, argv: argv(pid)?, cwd: cwd(pid) })
}

/// The exec path in a `KERN_PROCARGS2` answer (the path the process was exec'd as); `None` when
/// it is cut short, not UTF-8 or not absolute.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn procargs2_exec_path(data: &[u8]) -> Option<std::path::PathBuf> {
    let (_, rest) = data.split_first_chunk::<4>()?;
    let end = rest.iter().position(|b| *b == 0)?;
    let path = std::str::from_utf8(rest.get(..end)?).ok()?;
    std::path::Path::new(path).is_absolute().then(|| std::path::PathBuf::from(path))
}

/// The argv in a `KERN_PROCARGS2` answer: `argc` (i32), the exec path, NUL padding, then `argc`
/// NUL-terminated words. `None` when it is cut short or a word is not UTF-8.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn procargs2_argv(data: &[u8]) -> Option<Vec<String>> {
    procargs2_words(data).map(|(words, _)| words)
}

/// The environment in a `KERN_PROCARGS2` answer: the NUL-terminated `NAME=value` strings after
/// argv, up to the first empty one or the end. `None` when argv is cut short (`procargs2_argv`).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn procargs2_env(data: &[u8]) -> Option<Vec<(String, String)>> {
    let (_, rest) = procargs2_words(data)?;
    // The strings after the environment (the kernel's own, past an empty one) are not its.
    let end: usize =
        rest.split(|b| *b == 0).take_while(|w| !w.is_empty()).map(|w| w.len() + 1).sum();
    Some(env_pairs(rest.get(..end.min(rest.len()))?))
}

/// NUL-separated `NAME=value` strings (`/proc/<pid>/environ`): each as its name and value. One
/// that is not UTF-8 or has no `=` is skipped.
#[cfg_attr(not(any(target_os = "macos", target_os = "linux")), allow(dead_code))]
fn env_pairs(data: &[u8]) -> Vec<(String, String)> {
    data.split(|b| *b == 0)
        .filter_map(|w| std::str::from_utf8(w).ok()?.split_once('='))
        .filter(|(k, _)| !k.is_empty())
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect()
}

/// `procargs2_argv`'s words, and what follows the last of them (the environment).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn procargs2_words(data: &[u8]) -> Option<(Vec<String>, &[u8])> {
    let (count, rest) = data.split_first_chunk::<4>()?;
    let argc = usize::try_from(i32::from_ne_bytes(*count)).ok()?;
    // The exec path, then the NULs that pad it, then the argv words.
    let path_end = rest.iter().position(|b| *b == 0)?;
    let after_path = rest.get(path_end..)?;
    let start = after_path.iter().position(|b| *b != 0)?;
    let mut at = after_path.get(start..)?;
    let mut words = Vec::with_capacity(argc.min(4096));
    for _ in 0..argc {
        let end = at.iter().position(|b| *b == 0)?;
        let (word, rest) = at.split_at_checked(end)?;
        words.push(String::from_utf8(word.to_vec()).ok()?);
        at = rest.get(1..)?;
    }
    Some((words, at))
}

/// The argv in a `/proc/<pid>/cmdline`: NUL-terminated words. `None` when it is empty (a kernel
/// thread, or an exited process), not NUL-terminated (a process that rewrote it), or not UTF-8.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn cmdline_argv(data: &[u8]) -> Option<Vec<String>> {
    let body = data.strip_suffix(&[0])?;
    body.split(|b| *b == 0).map(|w| String::from_utf8(w.to_vec()).ok()).collect()
}

/// Every live process other than `leader` that runs under it: by parent chain, or in its process
/// group even after its parent exited (a group member reparented to init). Zombies are skipped:
/// they run nothing. `None` when `ps` fails, prints a line it cannot read or bytes that are not
/// UTF-8, or lists no `leader`:
/// a census that is not whole never says nothing runs.
pub fn under(leader: u32) -> Option<Vec<Under>> {
    let (ok, out) = ps("pid=,ppid=,pgid=,stat=,args=")?;
    // Output that is not text is not read as a whole census either.
    let out = String::from_utf8(out).ok().filter(|_| ok)?;
    under_in(&out, leader, own_group())
}

fn own_group() -> u32 {
    // SAFETY: getpgrp takes no arguments and cannot fail.
    unsafe { libc::getpgrp() as u32 }
}

/// [`under`] over `ps` output `table`; `own` is this process's group, never taken as the harness's.
pub fn under_in(table: &str, leader: u32, own: u32) -> Option<Vec<Under>> {
    let mut rows = Vec::new();
    for line in table.lines().filter(|l| !l.trim().is_empty()) {
        let mut f = line.split_whitespace();
        let mut num = || f.next()?.parse::<u32>().ok();
        let (pid, ppid, pgid) = (num()?, num()?, num()?);
        let stat = f.next()?;
        let args = f.collect::<Vec<_>>().join(" ");
        rows.push((pid, ppid, pgid, stat.starts_with('Z'), args));
    }
    let group = rows.iter().find(|r| r.0 == leader && !r.3)?.2;
    let mut tree = vec![leader];
    let mut found: Vec<Under> = Vec::new();
    let mut grew = true;
    while grew {
        grew = false;
        for (pid, ppid, pgid, zombie, args) in &rows {
            let taken = *pid == leader || *zombie || found.iter().any(|u| u.pid == *pid);
            let in_group = *pgid == group && group > 1 && group != own;
            if !taken && (tree.contains(ppid) || in_group) {
                found.push(Under { pid: *pid, ppid: *ppid, args: args.clone() });
                tree.push(*pid);
                grew = true;
            }
        }
    }
    Some(found)
}

#[cfg(test)]
mod census_tests;
