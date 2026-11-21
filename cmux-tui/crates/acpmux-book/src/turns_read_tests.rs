//! A page of turns: the group rows `folds.idx` lists, read alone.
use crate::folds::Folds;
use crate::log::{
    Anchor, Edge, HEADER_LEN, Log, MAX_FRAME_BYTES, MAX_ROWS, RECORD_OVERHEAD, RawRange, Side,
    Window,
};
use crate::testkit::{TURN_ROWS, folded_turns, ids, open, turn_group, turn_group_text};
use std::io::{Seek, SeekFrom, Write};

fn texts(page: &Window) -> Vec<Vec<u8>> {
    page.at.iter().map(|range| page.bytes[range.clone()].to_vec()).collect()
}

fn groups(turns: std::ops::RangeInclusive<u64>) -> Vec<u64> {
    turns.map(turn_group).collect()
}

/// The text a window carries for the closed fold whose group row is `group`.
fn window_text(log: &mut Log, folds: &Folds, group: u64) -> Vec<u8> {
    let window = log
        .read_window(
            Anchor::Row { id: group, side: Side::After },
            1,
            MAX_FRAME_BYTES,
            Some(folds),
            &[],
        )
        .unwrap();
    assert_eq!(ids(&window.rows), [group]);
    texts(&window).remove(0)
}

#[test]
fn turns_from_the_newest_end_read_one_group_row_each_and_page_back_to_the_first() {
    let home = tempfile::tempdir().unwrap();
    let turns = 1000;
    let (mut log, folds) = folded_turns(home.path(), 1, turns);
    // The open turn's group row would come next; it is not settled.
    let end = turn_group(turns + 1);
    let (stats, fold_stats) = (log.stats(), folds.stats());
    let page = log.read_turns(Edge::Before(end), usize::MAX, &folds).unwrap();
    let expected = groups(turns - MAX_ROWS as u64 + 1..=turns);
    assert_eq!(ids(&page.rows), expected);
    assert!(page.has_before && !page.has_after && page.refused.is_empty());
    assert_eq!((page.lo, page.hi), (expected[0], turn_group(turns)));
    // One search, a step and a read a group row; no row of a fold and no walk.
    assert_eq!(folds.stats().searches - fold_stats.searches, 1);
    assert!(folds.stats().entry_reads - fold_stats.entry_reads <= MAX_ROWS as u64);
    assert_eq!(log.stats().reads - stats.reads, MAX_ROWS as u64);
    assert_eq!(log.stats().walk_entries, stats.walk_entries);
    let read = texts(&page);
    for (row, text) in page.rows.iter().zip(&read) {
        assert_eq!(*text, turn_group_text((row.row_id - 1) / TURN_ROWS));
    }
    assert_eq!(read.last().unwrap(), &window_text(&mut log, &folds, turn_group(turns)));

    let mut all = ids(&page.rows);
    let mut page = page;
    while page.has_before {
        page = log.read_turns(Edge::Before(page.lo), usize::MAX, &folds).unwrap();
        assert!(page.has_after);
        let mut older = ids(&page.rows);
        older.append(&mut all);
        all = older;
    }
    assert_eq!(all, groups(1..=turns));

    let first = log.read_turns(Edge::After(0), usize::MAX, &folds).unwrap();
    assert_eq!(ids(&first.rows), groups(1..=MAX_ROWS as u64));
    assert!(!first.has_before && first.has_after);
}

#[test]
fn an_anchor_inside_a_fold_has_that_fold_before_it_never_on_both_sides() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, folds) = folded_turns(home.path(), 1, 10);
    let group = turn_group(5);
    // Its hidden rows and its visible reply.
    for anchor in group + 1..group + TURN_ROWS {
        let before = log.read_turns(Edge::Before(anchor), usize::MAX, &folds).unwrap();
        assert_eq!(ids(&before.rows), groups(1..=5), "before {anchor}");
        assert!(!before.has_before && before.has_after);
        let after = log.read_turns(Edge::After(anchor), usize::MAX, &folds).unwrap();
        assert_eq!(ids(&after.rows), groups(6..=10), "after {anchor}");
        assert!(after.has_before && !after.has_after);
    }
    // At the group row itself its turn is the anchor, on neither side.
    let before = log.read_turns(Edge::Before(group), usize::MAX, &folds).unwrap();
    assert_eq!(ids(&before.rows), groups(1..=4));
    assert!(!before.has_before && before.has_after);
    let after = log.read_turns(Edge::After(group), usize::MAX, &folds).unwrap();
    assert_eq!(ids(&after.rows), groups(6..=10));
    assert!(after.has_before && !after.has_after);
    // Past either end: empty, at the anchor, with the other side named.
    let first = log.read_turns(Edge::Before(turn_group(1)), usize::MAX, &folds).unwrap();
    assert!(first.rows.is_empty() && !first.has_before && first.has_after);
    assert_eq!((first.lo, first.hi), (turn_group(1), turn_group(1)));
    let last = turn_group(10) + TURN_ROWS - 1;
    let past = log.read_turns(Edge::After(last), usize::MAX, &folds).unwrap();
    assert!(past.rows.is_empty() && past.has_before && !past.has_after);
}

#[test]
fn a_turns_page_stops_at_max_bytes_and_takes_one_row_however_small() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, folds) = folded_turns(home.path(), 1, 10);
    let record =
        |log: &Log, turn| log.row(turn_group(turn)).unwrap().len as usize + RECORD_OVERHEAD;
    let three = (8..=10).map(|turn| record(&log, turn)).sum::<usize>();
    let end = Edge::Before(turn_group(11));
    let page = log.read_turns(end, three, &folds).unwrap();
    assert_eq!(ids(&page.rows), groups(8..=10));
    assert!(page.has_before && !page.has_after);
    let page = log.read_turns(end, three - 1, &folds).unwrap();
    assert_eq!(ids(&page.rows), groups(9..=10));
    assert!(page.has_before);
    for edge in [end, Edge::After(0)] {
        let page = log.read_turns(edge, 1, &folds).unwrap();
        assert_eq!(page.rows.len(), 1);
    }
}

#[test]
fn an_empty_book_has_no_turns() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    let folds = Folds::open(&home.path().join("folds.idx"), 0).unwrap();
    for (edge, at) in [(Edge::Before(u64::MAX), u64::MAX), (Edge::After(0), 0)] {
        let page = log.read_turns(edge, usize::MAX, &folds).unwrap();
        assert!(page.rows.is_empty() && page.refused.is_empty() && page.bytes.is_empty());
        assert!(!page.has_before && !page.has_after);
        assert_eq!((page.lo, page.hi), (at, at));
    }
}

#[test]
fn the_open_turn_is_not_in_a_turns_page() {
    // A book whose only turn is open: its user row and a tool row settled, its group row not.
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = open(home.path());
    for id in 2..=3 {
        log.append_settled(id, 1, RawRange::NONE, b"{}").unwrap();
    }
    let folds = Folds::open(&home.path().join("folds.idx"), 0).unwrap();
    let reads = log.stats().reads;
    for edge in [Edge::Before(u64::MAX), Edge::After(0), Edge::Before(1)] {
        let page = log.read_turns(edge, usize::MAX, &folds).unwrap();
        assert!(page.rows.is_empty() && !page.has_before && !page.has_after);
    }
    assert_eq!(log.stats().reads, reads);

    // Three settled turns, then an open one with settled rows of its own.
    let home = tempfile::tempdir().unwrap();
    let (mut log, folds) = folded_turns(home.path(), 1, 3);
    let open_group = turn_group(4);
    for id in open_group + 1..open_group + TURN_ROWS {
        log.append_settled(id, 1, RawRange::NONE, b"{}").unwrap();
    }
    for edge in [Edge::Before(u64::MAX), Edge::Before(open_group + 2), Edge::Before(open_group)] {
        let page = log.read_turns(edge, usize::MAX, &folds).unwrap();
        assert_eq!(ids(&page.rows), groups(1..=3));
        assert!(!page.has_before && !page.has_after);
    }
    let page = log.read_turns(Edge::After(turn_group(3)), usize::MAX, &folds).unwrap();
    assert!(page.rows.is_empty() && page.has_before && !page.has_after);
}

#[test]
fn a_hidden_group_row_is_carried_as_a_window_carries_it() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, mut folds) = folded_turns(home.path(), 1, 3);
    let hidden = turn_group(4);
    let text = br#"{"hidden":true}"#;
    log.append_settled(hidden, 1, RawRange::NONE, text).unwrap();
    for id in hidden + 1..hidden + TURN_ROWS {
        log.append_settled(id, 1, RawRange::NONE, b"{}").unwrap();
    }
    folds.append(hidden, hidden + TURN_ROWS - 1).unwrap();
    // A window steps over the whole fold and keeps its group row.
    let window =
        log.read_window(Anchor::End, MAX_ROWS, MAX_FRAME_BYTES, Some(&folds), &[]).unwrap();
    assert_eq!(*ids(&window.rows).last().unwrap(), hidden);
    let page = log.read_turns(Edge::Before(u64::MAX), usize::MAX, &folds).unwrap();
    assert_eq!(ids(&page.rows), groups(1..=4));
    assert_eq!(texts(&page).last().unwrap(), text);
    assert_eq!(texts(&page).last().unwrap(), &window_text(&mut log, &folds, hidden));
}

#[test]
fn a_damaged_group_row_is_a_hole_that_keeps_its_place() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, folds) = folded_turns(home.path(), 1, 5);
    let damaged = log.row(turn_group(3)).unwrap();
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .open(home.path().join(format!("rows/{:06}.seg", damaged.seg)))
        .unwrap();
    file.seek(SeekFrom::Start(u64::from(damaged.off))).unwrap();
    file.write_all(b"X").unwrap();
    let page = log.read_turns(Edge::Before(u64::MAX), usize::MAX, &folds).unwrap();
    assert_eq!(ids(&page.rows), [turn_group(1), turn_group(2), turn_group(4), turn_group(5)]);
    assert_eq!(page.refused, [turn_group(3)]);
    assert_eq!(texts(&page).len(), 4);
    let page = log.read_turns(Edge::After(turn_group(2)), 1, &folds).unwrap();
    assert!(page.rows.is_empty() && page.has_after);
    assert_eq!(
        (page.refused.as_slice(), page.lo, page.hi),
        ([turn_group(3)].as_slice(), turn_group(3), turn_group(3))
    );
}

#[test]
fn a_group_row_rows_idx_does_not_hold_is_a_hole_that_keeps_its_place() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, mut folds) = folded_turns(home.path(), 1, 3);
    // `folds.idx` lists turn 4; its rows were never settled, so `rows.idx` has no entry.
    let missing = turn_group(4);
    folds.append(missing, missing + TURN_ROWS - 1).unwrap();
    assert!(log.row(missing).is_none());
    let page = log.read_turns(Edge::Before(u64::MAX), usize::MAX, &folds).unwrap();
    assert_eq!(ids(&page.rows), groups(1..=3));
    assert_eq!(page.refused, [missing]);
    assert_eq!(texts(&page).len(), 3);
    assert_eq!((page.lo, page.hi), (turn_group(1), missing));
    // The hole spends no bytes but holds its place: a one-byte page is the hole alone.
    let page = log.read_turns(Edge::Before(u64::MAX), 1, &folds).unwrap();
    assert!(page.rows.is_empty() && page.has_before && !page.has_after);
    assert_eq!(
        (page.refused.as_slice(), page.lo, page.hi),
        ([missing].as_slice(), missing, missing)
    );
    let page = log.read_turns(Edge::After(turn_group(3)), usize::MAX, &folds).unwrap();
    assert!(page.rows.is_empty() && page.has_before && !page.has_after);
    assert_eq!(page.refused, [missing]);
}

/// The design doc's "no row of a fold is read (a counter says so)": every segment read a page
/// of turns makes is a group row's record, one each, whichever way it pages and from inside a
/// fold. `stats.reads` counts the reads; the reads' places say they are the group rows.
#[test]
fn a_page_of_turns_reads_its_group_rows_and_no_row_of_a_fold() {
    let home = tempfile::tempdir().unwrap();
    let turns = 40;
    let (mut log, folds) = folded_turns(home.path(), 1, turns);
    let edges = [
        Edge::Before(turn_group(turns + 1)),
        Edge::After(0),
        Edge::Before(turn_group(20) + 2),
        Edge::After(turn_group(7) + 1),
    ];
    // Armed here; each page then takes its own reads.
    log.take_segment_reads();
    for edge in edges {
        let page = log.read_turns(edge, usize::MAX, &folds).unwrap();
        let mut reads = log.take_segment_reads();
        assert!(!page.rows.is_empty() && page.refused.is_empty(), "{edge:?}");
        assert!(
            page.rows.iter().all(|row| (row.row_id - 1) % TURN_ROWS == 0),
            "{edge:?}: only group rows"
        );
        let mut records: Vec<(u32, u64)> =
            page.rows.iter().map(|row| (row.seg, u64::from(row.off) - HEADER_LEN as u64)).collect();
        reads.sort_unstable();
        records.sort_unstable();
        assert_eq!(reads, records, "{edge:?}: one read a group row, none of a fold's rows");
    }
}
