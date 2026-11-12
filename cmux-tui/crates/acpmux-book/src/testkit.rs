//! What the tests and the bench share: row texts that are the same for the same rowId, and
//! reading a log back.

use crate::log::{Anchor, Edge, Log, Options, Recovered, RowRef, Side};
use crate::row::{Row, RowKind};
use std::path::Path;

/// The length of row `id`'s body text. Every 40 ids hold the same mix: mostly a line or two, a
/// few paragraphs, one long reply.
pub(crate) fn filler_len(id: u64) -> usize {
    match id % 40 {
        0 => 2000,
        7 | 19 | 31 => 600,
        k => 40 + (k as usize * 13) % 160,
    }
}

/// The wire text of row `id`: the same bytes every time.
pub(crate) fn text(id: u64) -> Vec<u8> {
    let filler: String =
        (0..filler_len(id) as u64).map(|at| char::from(b'a' + ((id + at) % 26) as u8)).collect();
    let body = format!("{{\"md\":[\"{filler}\"]}}");
    let row = Row {
        id,
        rev: 1,
        kind: RowKind::ALL[(id % 10) as usize],
        turn: Some(id - id % 40),
        group: id.is_multiple_of(3).then_some(id - id % 8),
        at: 1_794_480_726 + id,
        open: false,
        body: &body,
        est: 1 + (filler.len() / 80) as u32,
    };
    let mut out = Vec::new();
    row.encode(None, &mut out).expect("a test row encodes");
    out
}

pub(crate) fn open(dir: &Path) -> (Log, Recovered) {
    Log::open(dir, Options::default()).expect("the book opens")
}

/// Settles rows `from..=to` in id order, each with [`text`].
pub(crate) fn settle(log: &mut Log, from: u64, to: u64) {
    for id in from..=to {
        log.append_settled(id, 1, &text(id)).expect("the row appends");
    }
}

/// The texts of `rows`, read through [`Log::fill`], and the reads it made.
pub(crate) fn texts(log: &mut Log, rows: &[RowRef]) -> (Vec<Vec<u8>>, u32) {
    let (mut buf, mut at) = (Vec::new(), Vec::new());
    let reads = log.fill(rows, &mut buf, &mut at).expect("the rows read");
    assert_eq!(at.len(), rows.len());
    (at.into_iter().map(|range| buf[range].to_vec()).collect(), reads)
}

pub(crate) fn ids(rows: &[RowRef]) -> Vec<u64> {
    rows.iter().map(|row| row.row_id).collect()
}

/// Every settled row of the book, read forward a window at a time: (rowId, text).
pub(crate) fn whole_book(log: &mut Log) -> Vec<(u64, Vec<u8>)> {
    let mut all = Vec::new();
    let mut window = log.window(Anchor::Row { id: 1, side: Side::After }, 400, 256 * 1024);
    loop {
        let (read, _) = texts(log, &window.rows);
        all.extend(ids(&window.rows).into_iter().zip(read));
        if !window.has_after {
            return all;
        }
        window = log.page(Edge::After(window.hi), 256 * 1024);
    }
}

/// Asserts the book holds exactly rows `1..=last`, each with [`text`].
pub(crate) fn assert_rows(log: &mut Log, last: u64) {
    let all = whole_book(log);
    assert_eq!(all.len() as u64, last, "the book's row count");
    for (at, (id, read)) in all.iter().enumerate() {
        assert_eq!(*id, at as u64 + 1);
        assert!(*read == text(*id), "row {id} reads back as it was written");
    }
}

/// Copies a book's files (not its lock) to `to`.
pub(crate) fn copy_book(from: &Path, to: &Path) {
    for sub in ["rows", "blobs"] {
        std::fs::create_dir_all(to.join(sub)).expect("mkdir");
        for entry in std::fs::read_dir(from.join(sub)).expect("read_dir") {
            let entry = entry.expect("entry");
            std::fs::copy(entry.path(), to.join(sub).join(entry.file_name())).expect("copy");
        }
    }
    for name in ["rows.idx", "seq.idx", "checkpoint"] {
        if from.join(name).exists() {
            std::fs::copy(from.join(name), to.join(name)).expect("copy");
        }
    }
}
