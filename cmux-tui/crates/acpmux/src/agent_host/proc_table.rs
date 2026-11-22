//! One reading of the machine's process table, shared by the idle censuses that run at once in
//! this process (`tree::under_shared`, `hub/idle_census.rs`).
//!
//! The census asks, for one harness, what runs under it: by parent chain, and by process group for
//! a member reparented to init. Reading the table is O(every process on the machine) (`ps -axww`),
//! and the idle pass read it once per harness: at 1,000 idle agents the pass spent most of its time
//! in `ps`, so agents hibernated at ~4.4 per second and 690-820 stayed live a day past their idle
//! deadline (cmux#43143). The pass now runs 16 censuses at once (`hub/idle.rs`), and one reading
//! answers every census that asked before it began: the censuses that asked while one ran wait for
//! the next and share it. A reading is indexed by parent and by group, so a census on it costs
//! O(the harness's own subtree).
//!
//! A census never uses a reading that began before it asked, so it sees everything a `ps` of its
//! own would have: a process its harness started a moment ago is in it.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use super::tree::Under;

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

/// The latest reading and when it began.
#[derive(Default)]
pub struct Shared {
    held: Mutex<Option<(Instant, Arc<Table>)>>,
    /// Held while a reading is taken: one `ps` at a time.
    reading: Mutex<()>,
}

impl Shared {
    /// The census of `leader`, asked at `asked`: from the held reading when it began at or after
    /// `asked` and lists `leader`, else from a fresh one `read` takes (begun at `clock()`, then
    /// held). Censuses that ask while a reading is taken wait for it to end, then take the next
    /// one together. `None` when `read` fails or the fresh table lists no live `leader`.
    pub fn under(
        &self,
        leader: u32,
        own: u32,
        asked: Instant,
        clock: impl Fn() -> Instant,
        read: impl FnOnce() -> Option<Table>,
    ) -> Option<Vec<Under>> {
        let _one = self.reading.lock().unwrap_or_else(|e| e.into_inner());
        let held = self.held.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some((began, table)) = held
            && began >= asked
            && let Some(found) = table.under(leader, own)
        {
            return Some(found);
        }
        self.fresh(leader, own, clock(), read)
    }

    /// The census of `leader` from a fresh reading `read` takes, begun at `began`; later censuses
    /// that asked before `began` share it.
    pub fn fresh(
        &self,
        leader: u32,
        own: u32,
        began: Instant,
        read: impl FnOnce() -> Option<Table>,
    ) -> Option<Vec<Under>> {
        let table = Arc::new(read()?);
        *self.held.lock().unwrap_or_else(|e| e.into_inner()) = Some((began, Arc::clone(&table)));
        table.under(leader, own)
    }
}

#[cfg(test)]
#[path = "proc_table_tests.rs"]
mod tests;
