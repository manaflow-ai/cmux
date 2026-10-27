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

/// Every process, from `ps`; empty when `ps` fails.
fn process_table() -> Vec<Started> {
    let mut ps = std::process::Command::new("ps");
    ps.args(["-axww", "-o", "pid=,ppid=,lstart="]);
    let Ok(out) = cmux_blocking::process::output(&mut ps) else {
        return Vec::new();
    };
    String::from_utf8_lossy(&out.stdout)
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
