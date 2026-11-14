use std::cell::Cell;
use std::time::{Duration, Instant};

use super::{MAX_AGE, Reading, Shared, Table};

/// A machine of `agents` harnesses (pid 10_000 + i, each its own group under the daemon, pid 2),
/// each with one MCP server under it, and `others` unrelated processes.
fn machine(agents: u32, others: u32) -> String {
    let mut t = String::from("1 0 1 Ss /sbin/init\n2 1 2 S acpmux daemon\n");
    for i in 0..agents {
        let (h, m) = (10_000 + i, 500_000 + i);
        t.push_str(&format!("{h} 2 {h} S fake_agent {i}\n{m} {h} {h} S mcp serve {i}\n"));
    }
    for i in 0..others {
        let p = 900_000 + i;
        t.push_str(&format!("{p} 1 {p} S other {i}\n"));
    }
    t
}

/// The scaling bug of cmux#43143: each harness's census read the whole machine (`ps -axww`), so an
/// idle pass over N agents cost N readings of an N-sized table. One reading must serve them all.
#[test]
fn one_reading_serves_every_census_of_an_idle_pass() {
    let text = machine(1_000, 5_000);
    let reads = Cell::new(0);
    let shared = Shared::default();
    let t0 = Instant::now();
    for i in 0..1_000u32 {
        let at = t0 + Duration::from_micros(u64::from(i));
        let read = || {
            reads.set(reads.get() + 1);
            Table::parse(&text)
        };
        let (found, reading) = shared.under(10_000 + i, 2, at, read).unwrap();
        assert_eq!(found.iter().map(|u| u.pid).collect::<Vec<_>>(), vec![500_000 + i]);
        assert_eq!(reading, if i == 0 { Reading::Fresh } else { Reading::Reused });
    }
    assert_eq!(reads.get(), 1, "the process table was read once per harness");
}

#[test]
fn a_reading_at_its_age_is_read_again() {
    let text = machine(2, 0);
    let shared = Shared::default();
    let t0 = Instant::now();
    let reads = Cell::new(0);
    let read = || {
        reads.set(reads.get() + 1);
        Table::parse(&text)
    };
    shared.under(10_000, 2, t0, read).unwrap();
    let (_, reading) = shared.under(10_001, 2, t0 + MAX_AGE, read).unwrap();
    assert_eq!((reads.get(), reading), (2, Reading::Fresh), "a reading at its age is not reused");
}

/// A harness started after the reading is not in it: a fresh reading is taken, which lists it.
#[test]
fn a_harness_the_reading_does_not_list_takes_a_fresh_one() {
    let before = machine(1, 0);
    let after = format!("{before}20000 2 20000 S fake_agent new\n");
    let shared = Shared::default();
    let t0 = Instant::now();
    shared.under(10_000, 2, t0, || Table::parse(&before)).unwrap();
    let (found, reading) = shared.under(20_000, 2, t0, || Table::parse(&after)).unwrap();
    assert_eq!((found.len(), reading), (0, Reading::Fresh));
    // And the fresh reading is the one held now.
    let (_, reading) = shared.under(20_000, 2, t0, || None).unwrap();
    assert_eq!(reading, Reading::Reused);
}

#[test]
fn fresh_always_reads_and_is_shared_after() {
    let text = machine(2, 0);
    let shared = Shared::default();
    let t0 = Instant::now();
    let reads = Cell::new(0);
    let read = || {
        reads.set(reads.get() + 1);
        Table::parse(&text)
    };
    shared.fresh(10_000, 2, t0, read).unwrap();
    shared.fresh(10_000, 2, t0, read).unwrap();
    assert_eq!(reads.get(), 2);
    assert_eq!(shared.under(10_001, 2, t0, read).unwrap().1, Reading::Reused);
    assert!(shared.fresh(10_000, 2, t0, || None).is_none(), "a failed reading says nothing");
}

/// The walk on the index finds what the old row-by-row loop did: children, group members
/// reparented to init and their children, no zombies, nothing of the daemon's own group.
#[test]
fn the_indexed_walk_takes_what_runs_under_the_harness() {
    let table = Table::parse(
        "1 0 1 Ss init\n100 1 100 S claude\n101 100 100 S mcp\n102 101 102 S node\n\
         103 1 100 S sleep\n104 100 100 Z rg\n106 103 106 S child-of-reparented\n200 1 200 S other\n",
    )
    .unwrap();
    let pids = |own| table.under(100, own).unwrap().iter().map(|u| u.pid).collect::<Vec<_>>();
    assert_eq!(pids(1), vec![101, 102, 103, 106]);
    assert_eq!(pids(100), vec![101, 102]);
}
