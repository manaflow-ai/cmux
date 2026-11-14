//! One reading of the machine's process table, shared by every idle census in this process
//! (`tree::under_shared`, `hub/idle_census.rs`).
//!
//! The census asks, for one harness, what runs under it: by parent chain, and by process group for
//! a member reparented to init. Reading the table is O(every process on the machine) (`ps -axww`),
//! and the idle pass read it once per harness: at 1,000 idle agents the pass spent most of its time
//! in `ps`, so agents hibernated at ~4.4 per second and 690-820 stayed live a day past their idle
//! deadline (cmux#43143). Now one reading serves every census for at most [`MAX_AGE`], indexed by
//! parent and by group, so a census on it costs O(the harness's own subtree).
//!
//! A reused reading can only let a harness end early, never keep one up for good: the census
//! takes a fresh reading for any harness the reused one does not list, and for any verdict but
//! "nothing else runs" (a process that ended since reads as unknown work). What a reused reading
//! cannot see is a process the harness started since, within [`MAX_AGE`]: the census runs only
//! while the harness is idle, with no turn and no start allowed, and its ending reads the tree
//! afresh (`tree::descendants`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::tree::Under;

/// How long one reading serves later censuses.
pub const MAX_AGE: Duration = Duration::from_secs(1);

/// One row of `ps -o pid=,ppid=,pgid=,stat=,args=`.
#[derive(Debug, Clone)]
struct Row {
    pid: u32,
    ppid: u32,
    pgid: u32,
    zombie: bool,
    args: String,
}

/// A whole process table, indexed by pid, parent and group.
#[derive(Debug, Default)]
pub struct Table {
    rows: Vec<Row>,
    by_pid: HashMap<u32, usize>,
    children: HashMap<u32, Vec<usize>>,
    groups: HashMap<u32, Vec<usize>>,
}

impl Table {
    /// `ps` output read as a whole table; `None` for a line it cannot read: a table that is not
    /// whole never says nothing runs.
    pub fn parse(table: &str) -> Option<Self> {
        let mut out = Self::default();
        for line in table.lines().filter(|l| !l.trim().is_empty()) {
            let mut f = line.split_whitespace();
            let mut num = || f.next()?.parse::<u32>().ok();
            let (pid, ppid, pgid) = (num()?, num()?, num()?);
            let zombie = f.next()?.starts_with('Z');
            let args = f.collect::<Vec<_>>().join(" ");
            let at = out.rows.len();
            out.by_pid.insert(pid, at);
            out.children.entry(ppid).or_default().push(at);
            out.groups.entry(pgid).or_default().push(at);
            out.rows.push(Row { pid, ppid, pgid, zombie, args });
        }
        Some(out)
    }

    /// Every live process other than `leader` under it: its children, theirs, and the members of
    /// its process group (unless that group is `own`, this process's, or 0/1) with theirs.
    /// Zombies are skipped. `None` when the table lists no live `leader`. In table order.
    /// O(the processes found), whatever the table's size.
    pub fn under(&self, leader: u32, own: u32) -> Option<Vec<Under>> {
        let group = self.rows.get(*self.by_pid.get(&leader)?).filter(|r| !r.zombie)?.pgid;
        let mut taken: Vec<usize> = Vec::new();
        let mut seen: std::collections::HashSet<u32> = std::collections::HashSet::from([leader]);
        let mut frontier: Vec<u32> = Vec::new();
        let mut take = |at: usize, frontier: &mut Vec<u32>, taken: &mut Vec<usize>| {
            if let Some(r) = self.rows.get(at)
                && !r.zombie
                && seen.insert(r.pid)
            {
                taken.push(at);
                frontier.push(r.pid);
            }
        };
        if group > 1 && group != own {
            for at in self.groups.get(&group).into_iter().flatten() {
                take(*at, &mut frontier, &mut taken);
            }
        }
        frontier.push(leader);
        while let Some(parent) = frontier.pop() {
            for at in self.children.get(&parent).into_iter().flatten() {
                take(*at, &mut frontier, &mut taken);
            }
        }
        taken.sort_unstable();
        Some(
            taken
                .into_iter()
                .filter_map(|at| self.rows.get(at))
                .map(|r| Under { pid: r.pid, ppid: r.ppid, args: r.args.clone() })
                .collect(),
        )
    }
}

/// Whether a census came from the held reading or a fresh one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reading {
    Reused,
    Fresh,
}

/// The shared reading and when it was taken.
#[derive(Default)]
pub struct Shared {
    held: Mutex<Option<(Instant, Arc<Table>)>>,
    /// Held while [`Shared::under`] takes a fresh reading.
    reading: Mutex<()>,
}

impl Shared {
    /// The census of `leader` from the held reading when it is younger than [`MAX_AGE`] and
    /// lists `leader`, else from a fresh one `read` takes (then held). `None` when `read` fails
    /// or the fresh table lists no live `leader`.
    pub fn under(
        &self,
        leader: u32,
        own: u32,
        now: Instant,
        read: impl FnOnce() -> Option<Table>,
    ) -> Option<(Vec<Under>, Reading)> {
        if let Some(found) = self.reuse(leader, own, now) {
            return Some((found, Reading::Reused));
        }
        // One reading at a time: censuses that run at once and all find the held one too old
        // wait for the first one's fresh reading and share it, instead of each running `ps`.
        let _one = self.reading.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(found) = self.reuse(leader, own, now) {
            return Some((found, Reading::Reused));
        }
        Some((self.fresh(leader, own, now, read)?, Reading::Fresh))
    }

    /// The census of `leader` from the held reading, when it is younger than [`MAX_AGE`] at `now`
    /// and lists `leader`.
    fn reuse(&self, leader: u32, own: u32, now: Instant) -> Option<Vec<Under>> {
        let (at, table) = self.held.lock().unwrap_or_else(|e| e.into_inner()).clone()?;
        if now.saturating_duration_since(at) >= MAX_AGE {
            return None;
        }
        table.under(leader, own)
    }

    /// The census of `leader` from a fresh reading `read` takes, which later censuses then share.
    pub fn fresh(
        &self,
        leader: u32,
        own: u32,
        now: Instant,
        read: impl FnOnce() -> Option<Table>,
    ) -> Option<Vec<Under>> {
        let table = Arc::new(read()?);
        *self.held.lock().unwrap_or_else(|e| e.into_inner()) = Some((now, Arc::clone(&table)));
        table.under(leader, own)
    }
}

#[cfg(test)]
#[path = "proc_table_tests.rs"]
mod tests;
