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
    let mut spared = vec![0, 1];
    let mut me = std::process::id();
    while me > 1 && !spared.contains(&me) {
        spared.push(me);
        me = table.iter().find(|p| p.pid == me).map_or(0, |p| p.ppid);
    }
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

/// SIGKILL each of `procs` that still runs as the same process.
pub fn kill_still_running(procs: &[Started]) {
    if procs.is_empty() {
        return;
    }
    let table = process_table();
    for p in procs {
        if !table.iter().any(|now| now.pid == p.pid && now.start == p.start) {
            continue;
        }
        let Ok(pid) = i32::try_from(p.pid) else { continue };
        // SAFETY: the pid runs with the start time it had under the host.
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }
}

/// A live process running under a harness, for the idle census (`hub/idle_census.rs`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Under {
    pub pid: u32,
    pub ppid: u32,
    /// Its command line as `ps` prints it (argv joined by spaces).
    pub args: String,
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
mod census_tests {
    use super::under_in;

    const TABLE: &str = "  1     0     1 Ss   /sbin/init
 100     1   100 S    claude --print
 101   100   100 S    cmux mcp serve
 102   101   102 S    node server.js
 103     1   100 S    sleep 600
 104   100   100 Z    [rg] <defunct>
 105   100   105 Ss   python3 -m http.server
 200     1   200 S    other
";

    #[test]
    fn the_census_takes_children_group_members_and_skips_zombies() {
        let pids: Vec<u32> = under_in(TABLE, 100, 1).unwrap().iter().map(|u| u.pid).collect();
        assert_eq!(pids, vec![101, 102, 103, 105]);
    }

    #[test]
    fn a_census_that_is_not_whole_says_nothing() {
        assert!(under_in(TABLE, 300, 1).is_none(), "a missing leader");
        assert!(under_in("100 1 100 S claude\nbad line\n", 100, 1).is_none(), "an unreadable line");
        assert!(under_in("104 1 104 Z claude\n", 104, 1).is_none(), "a zombie leader");
    }

    #[test]
    fn the_daemons_own_group_is_never_the_harnesss() {
        let pids: Vec<u32> = under_in(TABLE, 100, 100).unwrap().iter().map(|u| u.pid).collect();
        assert_eq!(pids, vec![101, 102, 105]);
    }
}
