//! What the tests and the bench share: row texts that are the same for the same rowId, and
//! reading a log back.

use crate::blobs::{Blobs, Body};
use crate::log::{Anchor, Edge, Log, MAX_BLOB_READ, Options, RawRange, Recovered, RowRef, Side};
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

/// A settled book whose last turn is represented by one closed fold. The group
/// and visible rows are identical at both gate sizes, so the reply has the same
/// bytes while the hidden turn grows from 10 to 100,000 rows.
pub(crate) fn folded_book(path: &Path, rows: u64) -> (Log, crate::folds::Folds) {
    let (mut log, _) = Log::open(path, Options::default()).expect("the folded book opens");
    let raw_file = log.append_raw_file(b"fixture/folded-turn.ndjson").expect("fixture raw source");
    for id in 2..=rows {
        log.append_settled(id, 1, RawRange { file: raw_file, off: id, len: 1 }, b"{}")
            .expect("the folded row appends");
    }
    log.append_settled(
        1,
        1,
        RawRange { file: raw_file, off: rows.saturating_add(1), len: 1 },
        br#"{"body":{"out":[[2,3]]}}"#,
    )
    .expect("the fold group appends");
    log.sync().expect("the folded rows sync");
    let mut folds = crate::folds::Folds::open(&path.join("folds.idx"), 0).expect("fold index");
    folds.append(1, rows).expect("the fold boundary appends");
    folds.sync().expect("the fold boundary syncs");
    (log, folds)
}

/// Rows per turn of [`folded_turns`]: the group, two hidden rows, the visible reply.
pub(crate) const TURN_ROWS: u64 = 4;
/// The text of a [`folded_turns`] reply row.
pub(crate) const REPLY: &[u8] = br#"{"body":{"md":["the reply"]}}"#;

/// The group row of turn `turn` in [`folded_turns`].
pub(crate) fn turn_group(turn: u64) -> u64 {
    turn * TURN_ROWS + 1
}

/// The group text of turn `turn` in [`folded_turns`]: its `out` names the reply row.
pub(crate) fn turn_group_text(turn: u64) -> Vec<u8> {
    let reply = turn_group(turn) + TURN_ROWS - 1;
    format!(r#"{{"body":{{"out":[[{reply},{reply}]]}}}}"#).into_bytes()
}

/// A settled book of closed folded turns `first..first + turns`, in row order: each turn is
/// a group row, two hidden rows and a visible reply row named by the group's `out`, and one
/// `folds.idx` entry. Turn numbers fix the row ids and texts, so two books that end at the
/// same turn have the same last turns, row for row, whatever number of turns comes before.
pub(crate) fn folded_turns(path: &Path, first: u64, turns: u64) -> (Log, crate::folds::Folds) {
    let (mut log, _) = Log::open(path, Options::default()).expect("the folded book opens");
    // A raw range on every row spares an fsync per append, as a translated book does.
    let raw_file = log.append_raw_file(b"fixture/folded-turns.ndjson").expect("raw source");
    let mut folds = crate::folds::Folds::open(&path.join("folds.idx"), 0).expect("fold index");
    for turn in first..first + turns {
        let group = turn_group(turn);
        let group_text = turn_group_text(turn);
        let texts: [&[u8]; 4] = [&group_text, b"{}", b"{}", REPLY];
        for (id, text) in (group..).zip(texts) {
            log.append_settled(id, 1, RawRange { file: raw_file, off: id, len: 1 }, text)
                .expect("the turn's row appends");
        }
        folds.append(group, group + TURN_ROWS - 1).expect("the turn's fold appends");
    }
    log.sync().expect("the turns sync");
    folds.sync().expect("the folds sync");
    (log, folds)
}

pub(crate) struct BlobFixture {
    pub(crate) log: Log,
    pub(crate) blobs: Blobs,
    pub(crate) body: Body,
    pub(crate) offset: u64,
}

/// Builds both settled and open large bodies before a gate's timed rounds.
pub(crate) fn blob_fixture(path: &Path, bytes: usize) -> BlobFixture {
    let (log, _) = open(path);
    let mut blobs = Blobs::open(path).expect("the open body store opens");
    let mut body = Body::new(1).expect("the open body row");
    // The requested size includes {"text":""}. Build only one large allocation;
    // settling streams the same JSON while retaining the open field's file.
    let text_bytes = bytes.checked_sub(br#"{"text":""}"#.len()).expect("body size");
    let mut value = String::with_capacity(text_bytes.saturating_add(2));
    value.push('"');
    value.extend(std::iter::repeat_n('x', text_bytes));
    value.push('"');
    blobs.set(&mut body, "text", &value, false).expect("the open body writes");
    assert_eq!(body.len(), bytes as u64);
    assert!(blobs.settle(&body).expect("the settled body streams").is_none());
    BlobFixture { log, blobs, body, offset: bytes.saturating_sub(MAX_BLOB_READ) as u64 }
}

/// Settles rows `from..=to` in id order, each with [`text`].
pub(crate) fn settle(log: &mut Log, from: u64, to: u64) {
    for id in from..=to {
        log.append_settled(id, 1, RawRange::NONE, &text(id)).expect("the row appends");
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
    let mut window = log.window(Anchor::Row { id: 1, side: Side::After }, 400, 256 * 1024).unwrap();
    loop {
        let (read, _) = texts(log, &window.rows);
        all.extend(ids(&window.rows).into_iter().zip(read));
        if !window.has_after {
            return all;
        }
        window = log.page(Edge::After(window.hi), 256 * 1024).unwrap();
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
    for name in ["rows.idx", "seq.idx", "checkpoint", "raw.map", "rows.undo", "folds.idx"] {
        if from.join(name).exists() {
            std::fs::copy(from.join(name), to.join(name)).expect("copy");
        }
    }
}
