//! The v2 gate rows, one file per row of the design doc's PR table: `pr03d.rs` holds every
//! `v2.pr03d.*` row. A PR that adds or changes a gate's row edits its own row's file, so two v2 PRs
//! never change one shared file. The list below has a file for every row of the table, so a new
//! gate's row goes in a file that is already listed; a new row of the table adds its file here.

use super::GateRow;

macro_rules! groups {
    ($($prefix:ident),* $(,)?) => {
        $(pub mod $prefix;)*

        /// Every row file, in the design doc's PR order, with the prefix its rows' names carry.
        pub const GROUPS: &[(&str, &[GateRow])] = &[$((stringify!($prefix), $prefix::ROWS)),*];
    };
}

groups! {
    pr00,
    pr00b,
    pr01,
    pr01b,
    pr02,
    pr02b,
    pr02c,
    pr02d,
    pr03,
    pr03a,
    pr03a2,
    pr03a3,
    pr03b,
    pr03c,
    pr03d,
    pr04,
    pr04b,
    pr05,
    pr05b,
    pr05c,
    pr05d,
    pr05e,
    pr05f,
    pr05g,
    pr05h,
    pr05i,
    pr06,
    pr07,
    pr07b,
    pr07c,
    pr07d,
    pr07e,
    pr07f,
    pr07g,
    pr08,
    pr08b,
    pr08c,
    pr09,
    pr10,
    pr11,
    pr12,
    pr13,
}

const fn row_count(groups: &[(&str, &[GateRow])]) -> usize {
    let mut count = 0;
    let mut group = 0;
    while group < groups.len() {
        count += groups[group].1.len();
        group += 1;
    }
    count
}

const fn first_row(groups: &[(&str, &[GateRow])]) -> GateRow {
    let mut group = 0;
    while group < groups.len() {
        if !groups[group].1.is_empty() {
            return groups[group].1[0];
        }
        group += 1;
    }
    panic!("the v2 gate registry has no row")
}

const fn all_rows<const N: usize>(groups: &[(&str, &[GateRow])]) -> [GateRow; N] {
    let mut all = [first_row(groups); N];
    let mut at = 0;
    let mut group = 0;
    while group < groups.len() {
        let rows = groups[group].1;
        let mut row = 0;
        while row < rows.len() {
            all[at] = rows[row];
            at += 1;
            row += 1;
        }
        group += 1;
    }
    assert!(at == N);
    all
}

/// The rows of every file, file after file in `GROUPS`'s order.
pub const ALL: [GateRow; row_count(GROUPS)] = all_rows(GROUPS);
