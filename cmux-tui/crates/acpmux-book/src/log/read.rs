//! Reading a book: windows and pages by rowId, a resume by seq, and the one copy of row text
//! out of the segments.
//!
//! A window, a page and a resume are lists of [`RowRef`]: byte ranges of stored row text. They
//! are found from the indexes (and, for a resume, the record headers); no row is parsed and no
//! reply is built here. [`Log::fill`] then reads the ranges, one read per run of neighbouring
//! records, and the caller copies the row texts into its frame.
//!
//! Every reply is bounded whatever the caller asks for: [`MAX_ROWS`] rows, [`MAX_FRAME_BYTES`]
//! for a window or a resume, [`MAX_PAGE_BYTES`] for a page.

use super::index::Entry;
use super::record::{HEADER_LEN, HEADER_LEN_U32, HEADER_LEN_U64, Header};
use super::{Error, Log, RawRange, SEQ_STRIDE};
use std::ops::Range;

/// The most rows one window, page or resume returns.
pub const MAX_ROWS: usize = 4096;
/// The most row text one window or resume returns: one frame.
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;
/// The most row text one page returns.
pub const MAX_PAGE_BYTES: usize = 256 * 1024;
/// The most segment bytes one read covers: a full page of small rows with their record
/// overhead, with room for records of other rows that lie between them.
const SPAN_BYTES: u64 = (MAX_PAGE_BYTES + 128 * 1024) as u64;
/// The most index entries one walk looks at. A book has few unsettled ids between settled ones;
/// this bounds a walk across a long stretch of them (a book being rebuilt from its tail).
const WALK_ENTRIES: u32 = 65_536;
/// A resume reads record headers this much at a time.
const RESUME_CHUNK: usize = 64 * 1024;

/// A byte range of stored row text: `len` bytes at `off` in segment `seg`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RowRef {
    pub row_id: u64,
    pub rev: u32,
    /// The seq of the record, from [`Log::since`]; 0 from a window, a page or [`Log::row`]
    /// (the index does not hold it).
    pub seq: u64,
    pub seg: u32,
    /// Where the row text starts in the segment (40 bytes after its record).
    pub off: u32,
    pub len: u32,
    /// The raw bytes that produced this record. Resume rows carry it immediately because they
    /// inspect headers; windows and pages leave it empty until [`Log::raw_range`] is requested.
    pub raw: RawRange,
}

impl RowRef {
    pub(super) fn of(row_id: u64, seq: u64, entry: &Entry) -> RowRef {
        RowRef {
            row_id,
            rev: entry.rev,
            seq,
            seg: entry.seg,
            off: entry.off.saturating_add(HEADER_LEN_U32),
            len: entry.len,
            raw: RawRange::NONE,
        }
    }
}

/// Which side of an anchor row a window lies on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    /// The window ends with the anchor row.
    Before,
    /// The window starts with the anchor row.
    After,
    /// The anchor row is in the middle: half the window from it on, the rest before it, and
    /// what one side does not use goes to the other.
    Around,
}

/// Where a window is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Anchor {
    /// The last rows of the book.
    End,
    /// At a row. The row need not be settled: the window is of the settled rows around its id.
    Row { id: u64, side: Side },
}

/// Which page: the rows just before a row, or just after it (the row itself is not in the page).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Edge {
    Before(u64),
    After(u64),
}

/// Settled rows in book order.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Window {
    /// The rows, by rising rowId.
    pub rows: Vec<RowRef>,
    /// The lowest and highest rowId this reply accounts for: every settled row from `lo` to `hi`
    /// is in `rows`. A caller that wants more asks for the page before `lo` or after `hi`.
    pub lo: u64,
    pub hi: u64,
    /// Whether settled rows exist before `lo`, and after `hi`.
    pub has_before: bool,
    pub has_after: bool,
}

/// What a cursor missed, in change order.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Since {
    /// The records after the cursor, by rising seq. A row that changed twice is here twice.
    pub rows: Vec<RowRef>,
    /// The cursor after these rows: the seq to resume from next.
    pub cursor: u64,
    /// Whether more records follow `cursor` (the reply was cut at its byte or row bound).
    pub more: bool,
}

/// The segment bytes one read would cover: from the first record's header to the end of the
/// last row text.
#[derive(Clone, Copy)]
struct Span {
    seg: u32,
    lo: u64,
    hi: u64,
}

impl Span {
    fn of(row: &RowRef) -> Span {
        let text = u64::from(row.off);
        Span {
            seg: row.seg,
            lo: text.saturating_sub(HEADER_LEN_U64),
            hi: text.saturating_add(u64::from(row.len)),
        }
    }

    /// This span widened to hold `row` too; `None` when that is another segment or would make
    /// the read longer than [`SPAN_BYTES`].
    fn with(self, row: &RowRef) -> Option<Span> {
        let other = Span::of(row);
        let joined = Span { seg: self.seg, lo: self.lo.min(other.lo), hi: self.hi.max(other.hi) };
        (other.seg == self.seg && joined.hi.saturating_sub(joined.lo) <= SPAN_BYTES)
            .then_some(joined)
    }
}

/// What a walk may still take.
struct Budget {
    rows: usize,
    bytes: u64,
    /// Take the first row even when it is over `bytes`, so a reply is never empty for its size.
    first_free: bool,
    /// Stop where the rows taken would no longer come in one read.
    one_read: bool,
}

impl Log {
    /// Walks rowIds from `start`, up or down, collecting settled rows into `out` until the
    /// budget is spent or the book ends. Returns the last id it accounted for (taken, or not
    /// settled), `None` when it accounted for none. Index entries only.
    fn walk(
        &self,
        start: u64,
        up: bool,
        budget: &mut Budget,
        out: &mut Vec<RowRef>,
    ) -> Option<u64> {
        let mut id = start;
        let mut edge = None;
        let mut looked = 0u32;
        let mut span: Option<Span> = None;
        while id != 0
            && id >= self.min_row
            && id <= self.max_row
            && budget.rows != 0
            && looked < WALK_ENTRIES
        {
            looked = looked.saturating_add(1);
            if let Some(entry) = self.entry(id) {
                let row = RowRef::of(id, 0, &entry);
                let len = u64::from(entry.len);
                if len > budget.bytes && !budget.first_free {
                    break;
                }
                if budget.one_read {
                    let joined = match span {
                        None => Some(Span::of(&row)),
                        Some(span) => span.with(&row),
                    };
                    if joined.is_none() {
                        break;
                    }
                    span = joined;
                }
                out.push(row);
                budget.first_free = false;
                budget.rows = budget.rows.saturating_sub(1);
                budget.bytes = budget.bytes.saturating_sub(len);
            }
            edge = Some(id);
            id = if up { id.saturating_add(1) } else { id.saturating_sub(1) };
        }
        edge
    }

    fn window_of(&self, rows: Vec<RowRef>, lo: u64, hi: u64) -> Window {
        Window {
            rows,
            lo,
            hi,
            has_before: self.min_row != 0 && lo > self.min_row,
            has_after: hi < self.max_row,
        }
    }

    /// The settled rows around `anchor`: at most `rows` of them ([`MAX_ROWS`] at most) and
    /// `max_bytes` of row text ([`MAX_FRAME_BYTES`] at most), always at least one when one
    /// exists. Reads index entries only: the cost is the window's, for a book of any length.
    pub fn window(&self, anchor: Anchor, rows: usize, max_bytes: usize) -> Window {
        let mut budget = Budget {
            rows: rows.min(MAX_ROWS),
            bytes: max_bytes.min(MAX_FRAME_BYTES) as u64,
            first_free: true,
            one_read: false,
        };
        let mut out = Vec::with_capacity(budget.rows.min(512));
        match anchor {
            Anchor::End => {
                let lo = self.walk(self.max_row, false, &mut budget, &mut out);
                out.reverse();
                self.window_of(out, lo.unwrap_or(self.max_row), self.max_row)
            }
            Anchor::Row { id, side: Side::Before } => {
                let start = id.min(self.max_row);
                let lo = self.walk(start, false, &mut budget, &mut out);
                out.reverse();
                self.window_of(out, lo.unwrap_or(start), start)
            }
            Anchor::Row { id, side: Side::After } => {
                let start = id.max(self.min_row);
                let hi = self.walk(start, true, &mut budget, &mut out);
                self.window_of(out, start, hi.unwrap_or(start))
            }
            Anchor::Row { id, side: Side::Around } => {
                let start = id.max(self.min_row);
                // Half from the anchor on, then everything left before it, then what the rows
                // before it did not use goes after again.
                let mut ahead = Budget {
                    rows: budget.rows.saturating_sub(budget.rows / 2),
                    // The anchor may be the one oversized row, but it still consumes the shared
                    // byte budget when it fits. Rows before and after it must not each get a half
                    // budget after the anchor has been counted.
                    bytes: budget.bytes,
                    first_free: true,
                    one_read: false,
                };
                let kept_rows = budget.rows / 2;
                let mut after = Vec::new();
                let mut hi = self.walk(start, true, &mut ahead, &mut after);
                budget = Budget {
                    rows: kept_rows.saturating_add(ahead.rows),
                    bytes: ahead.bytes,
                    first_free: after.is_empty(),
                    one_read: false,
                };
                let below = start.saturating_sub(1).min(self.max_row);
                let lo = self.walk(below, false, &mut budget, &mut out);
                out.reverse();
                if budget.rows != 0 && budget.bytes != 0 {
                    let next = hi.map_or(start, |hi| hi.saturating_add(1));
                    budget.first_free = false;
                    hi = self.walk(next, true, &mut budget, &mut after).or(hi);
                }
                out.append(&mut after);
                self.window_of(out, lo.unwrap_or(start), hi.unwrap_or(start))
            }
        }
    }

    /// The settled rows just before or just after a row: at most `max_bytes` of row text
    /// ([`MAX_PAGE_BYTES`] at most), always at least one when one exists. The page ends where
    /// its rows would stop coming in one read (a segment's end, or a row whose record lies far
    /// from the others), so [`Log::fill`] of a page is always exactly one read; the caller asks
    /// for the next page from `lo` or `hi`. Reads index entries only.
    pub fn page(&self, edge: Edge, max_bytes: usize) -> Window {
        let mut budget = Budget {
            rows: MAX_ROWS,
            bytes: max_bytes.min(MAX_PAGE_BYTES) as u64,
            first_free: true,
            one_read: true,
        };
        let mut out = Vec::new();
        match edge {
            Edge::Before(id) => {
                let start = id.saturating_sub(1).min(self.max_row);
                let lo = self.walk(start, false, &mut budget, &mut out);
                out.reverse();
                self.window_of(out, lo.unwrap_or(id.max(1)), start)
            }
            Edge::After(id) => {
                let start = id.saturating_add(1).max(self.min_row);
                let hi = self.walk(start, true, &mut budget, &mut out);
                self.window_of(out, start, hi.unwrap_or(id.min(self.max_row)))
            }
        }
    }

    /// The records after `cursor`, in change order: at most `max_bytes` of row text
    /// ([`MAX_FRAME_BYTES`] at most), always at least one when one exists. Starts at the
    /// `seq.idx` entry at or before the cursor, so it reads what was missed (and at most 255
    /// records before it), never the book. A cursor at or past the last seq gets nothing.
    pub fn since(&mut self, cursor: u64, max_bytes: usize) -> Result<Since, Error> {
        let mut since = Since { rows: Vec::new(), cursor: cursor.min(self.last_seq), more: false };
        if cursor >= self.last_seq {
            return Ok(since);
        }
        let slot = cursor.saturating_add(1) / SEQ_STRIDE;
        let (mut seg, mut offset) = if slot == 0 {
            (1u32, super::SEGMENT_HEADER_LEN)
        } else {
            let (seg, off) = self
                .seqs
                .get(slot)?
                .ok_or(Error::Corrupt("seq.idx has no entry before the cursor"))?;
            (seg, u64::from(off))
        };
        let mut left = max_bytes.min(MAX_FRAME_BYTES) as u64;
        let mut chunk = vec![0u8; RESUME_CHUNK];
        loop {
            let read = self.read_segment(seg, offset, &mut chunk)?;
            if read == 0 {
                // The end of a segment: the next record starts the next one.
                if seg >= self.tail.seg {
                    return Ok(since);
                }
                seg = seg.saturating_add(1);
                offset = super::SEGMENT_HEADER_LEN;
                continue;
            }
            let mut at = 0usize;
            // Step over whole headers; a record's text may run past the chunk, the next read
            // starts at the record after it.
            while let Some(rest) = chunk.get(at..read).filter(|rest| rest.len() >= HEADER_LEN) {
                let header =
                    Header::parse(rest).ok_or(Error::Corrupt("a segment record is damaged"))?;
                if header.seq > cursor {
                    let len = u64::from(header.len);
                    let full = len > left || since.rows.len() >= MAX_ROWS;
                    if full && !since.rows.is_empty() {
                        since.more = true;
                        return Ok(since);
                    }
                    let text = offset.saturating_add(HEADER_LEN_U64);
                    since.rows.push(RowRef {
                        row_id: header.row_id,
                        rev: header.rev,
                        seq: header.seq,
                        seg,
                        off: u32::try_from(text)
                            .map_err(|_| Error::Corrupt("a segment is past 4 GiB"))?,
                        len: header.len,
                        raw: RawRange {
                            file: header.raw_file,
                            off: header.raw_off,
                            len: header.raw_len,
                        },
                    });
                    since.cursor = header.seq;
                    left = left.saturating_sub(len);
                }
                if header.seq >= self.last_seq {
                    return Ok(since);
                }
                at = at.saturating_add(header.record_len());
                offset = offset.saturating_add(header.record_len() as u64);
            }
            if at == 0 {
                // Fewer bytes than a header where a record must start.
                return Err(Error::Corrupt("a segment ends inside a record"));
            }
        }
    }

    /// Reads the row texts of `rows` out of the segments. `buf` (cleared first) receives the
    /// segment bytes and `at[i]` is where row `i`'s text lies in it; the caller copies those
    /// slices into its frame, so a row text is copied once and never parsed. Rows whose records
    /// are neighbours in one segment come in one read: a window is usually one read, a page
    /// always is. Returns the reads made.
    ///
    /// Each row's record header is checked against the row asked for, so an index entry that
    /// does not match its record is [`Error::CorruptRow`], never another row's text.
    pub fn fill(
        &mut self,
        rows: &[RowRef],
        buf: &mut Vec<u8>,
        at: &mut Vec<Range<usize>>,
    ) -> Result<u32, Error> {
        buf.clear();
        at.clear();
        let mut reads = 0u32;
        let mut rest = rows;
        while let Some(first) = rest.first() {
            let mut span = Span::of(first);
            let mut count = 1usize;
            while let Some(joined) = rest.get(count).and_then(|row| span.with(row)) {
                span = joined;
                count = count.saturating_add(1);
            }
            let (run, after) = rest.split_at_checked(count).unwrap_or((rest, &[]));
            rest = after;

            let base = buf.len();
            let len = usize::try_from(span.hi.saturating_sub(span.lo)).unwrap_or(usize::MAX);
            buf.resize(base.saturating_add(len), 0);
            let read = match buf.get_mut(base..) {
                Some(space) => self.read_segment(span.seg, span.lo, space)?,
                None => 0,
            };
            reads = reads.saturating_add(1);
            if read != len {
                return Err(Error::CorruptRow {
                    row_id: run
                        .iter()
                        .find(|row| u64::from(row.off) + u64::from(row.len) > span.lo + read as u64)
                        .unwrap_or(first)
                        .row_id,
                    reason: "a row index entry points past its segment",
                });
            }
            for row in run {
                let header_at = usize::try_from(
                    u64::from(row.off).saturating_sub(HEADER_LEN_U64).saturating_sub(span.lo),
                )
                .unwrap_or(usize::MAX)
                .saturating_add(base);
                let header = buf.get(header_at..).and_then(Header::parse);
                let same = header.is_some_and(|header| {
                    header.row_id == row.row_id && header.rev == row.rev && header.len == row.len
                });
                if !same {
                    return Err(Error::CorruptRow {
                        row_id: row.row_id,
                        reason: "a row index entry does not match its record",
                    });
                }
                if let Some(header) = header
                    && header.raw_len != 0
                    && (header.raw_file == 0 || header.raw_file > self.raw_files)
                {
                    return Err(Error::CorruptRow {
                        row_id: row.row_id,
                        reason: "a record names a raw file absent from raw.map",
                    });
                }
                let text = header_at.saturating_add(HEADER_LEN);
                at.push(text..text.saturating_add(row.len as usize));
            }
        }
        Ok(reads)
    }
}
