//! Reading a book: windows and pages by rowId, a resume by seq, and the one copy of row text
//! out of the segments.
//!
//! Windows, pages and resumes return [`RowRef`] ranges after checking each record's header
//! and CRC. Closed folds parse only their group row's visible ranges; hidden rows are skipped.
//! A window or page carries its rows' text from the one read that checked them
//! ([`Window::bytes`]); [`Log::fill`] reads checked ranges for other callers.
//!
//! One read does at most one search of `folds.idx`, then steps to neighbouring entries as its
//! walk moves; rows between two folds cost no read of the index.
//!
//! Windows and pages hold at most [`MAX_ROWS`] visible rows. The record-byte bounds are
//! [`MAX_FRAME_BYTES`] for a window or resume and [`MAX_PAGE_BYTES`] for a page.

use super::index::Entry;
use super::record::{Check, HEADER_LEN, HEADER_LEN_U32, HEADER_LEN_U64, Header};
use super::{Error, Log, RawRange, SEQ_STRIDE};
use crate::folds::{Entry as FoldEntry, Folds};
use serde_json::Value;
use std::collections::BTreeMap;
use std::ops::Range;

/// The most visible rows one window or page accounts for.
pub const MAX_ROWS: usize = 400;
/// The most record bytes one window or resume accounts for: one frame.
pub const MAX_FRAME_BYTES: usize = 256 * 1024;
/// The most record bytes one page accounts for.
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
    /// The first and last candidates, including refused rows but excluding folded-away rows.
    /// A caller continues before `lo` or after `hi`. An empty reply keeps its requested edge.
    pub lo: u64,
    pub hi: u64,
    /// Whether the walk has unexamined rows before or after the range it accounted for.
    pub has_before: bool,
    pub has_after: bool,
    /// Rows whose headers or CRCs were refused. They count in the window's bounds,
    /// but are holes in its rows.
    pub refused: Vec<u64>,
    /// The rows' texts, from the read that checked their records: `at[i]` is where the text of
    /// `rows[i]` lies in `bytes`. Other record bytes (headers, CRCs) may lie between texts.
    pub bytes: Vec<u8>,
    pub at: Vec<Range<usize>>,
}

/// What a cursor missed, in change order.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Since {
    /// The records after the cursor, by rising seq. A row that changed twice is here twice.
    pub rows: Vec<RowRef>,
    /// The cursor after these rows: the seq to resume from next.
    pub cursor: u64,
    /// Whether more records follow `cursor` (the reply was cut at its byte bound).
    pub more: bool,
    /// Replay encountered a refused record. The caller must give a fresh window;
    /// the rows before it are valid, and the cursor never advances over damage.
    pub stopped_on_refusal: bool,
}

/// The cost of starting a resume at its sparse sequence-index block.
/// `Over` also covers two or more segment transitions, without reading their lengths.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResumeSize {
    Within(u64),
    Over,
}

/// The segment bytes one read covers, including record headers and CRCs.
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
            hi: text.saturating_add(u64::from(row.len)).saturating_add(4),
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

    /// [`Span::with`] when `row`'s record starts where this span ends, so a read of the joined
    /// span holds no other record's bytes.
    fn followed_by(self, row: &RowRef) -> Option<Span> {
        if Span::of(row).lo == self.hi { self.with(row) } else { None }
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

/// Per-request fold state shared by all directions of a window walk.
struct FoldRead<'a> {
    index: Option<&'a Folds>,
    open: &'a [u64],
    ranges: BTreeMap<u64, Vec<(u64, u64)>>,
    /// Exact group records already checked while reading their visible ranges, with their
    /// text. The sole writer cannot change them during this request, so neither validation
    /// nor the reply reads them twice.
    validated: BTreeMap<u64, (RowRef, Vec<u8>)>,
    /// Where the walk is in `folds.idx`; `None` until the request's one search.
    cursor: Option<FoldCursor>,
}

/// Two neighbouring entries of `folds.idx`: the rows from `below.group` up to (not including)
/// `above.group` are in `below`'s fold or in the gap after it, so they need no index read.
#[derive(Clone, Copy)]
struct FoldCursor {
    /// The position of `above`; `below` is the entry just before it.
    above_at: u64,
    /// `None` before the first entry.
    below: Option<FoldEntry>,
    /// `None` after the last entry.
    above: Option<FoldEntry>,
}

impl<'a> FoldRead<'a> {
    fn new(index: Option<&'a Folds>, open: &'a [u64]) -> Self {
        Self { index, open, ranges: BTreeMap::new(), validated: BTreeMap::new(), cursor: None }
    }

    /// The closed fold holding `row_id`, if any. The first call searches the index; later
    /// calls step from the cursor to neighbouring entries, one 16-byte read each, and a row
    /// in the gap the cursor spans reads nothing.
    fn locate(&mut self, row_id: u64) -> Result<Option<FoldEntry>, Error> {
        let Some(index) = self.index else { return Ok(None) };
        let mut cursor = match self.cursor {
            Some(cursor) => cursor,
            None => {
                let (above_at, below) = match index.search(row_id)? {
                    Some((position, entry)) => (position.saturating_add(1), Some(entry)),
                    None => (0, None),
                };
                FoldCursor { above_at, below, above: index.entry_at(above_at)? }
            }
        };
        loop {
            if let Some(below) = cursor.below
                && row_id < below.group
            {
                cursor.above = Some(below);
                cursor.above_at = cursor.above_at.saturating_sub(1);
                cursor.below = match cursor.above_at.checked_sub(1) {
                    Some(position) => index.entry_at(position)?,
                    None => None,
                };
                continue;
            }
            if let Some(above) = cursor.above
                && row_id >= above.group
            {
                cursor.below = Some(above);
                cursor.above_at = cursor.above_at.saturating_add(1);
                cursor.above = index.entry_at(cursor.above_at)?;
                continue;
            }
            break;
        }
        self.cursor = Some(cursor);
        Ok(cursor.below.filter(|fold| row_id <= fold.last))
    }
}

impl Log {
    /// The single size bound used by every read entry point.
    pub fn bound(requested: usize, cap: usize) -> usize {
        requested.min(cap)
    }

    /// Walks rowIds from `start`, up or down, collecting settled rows into `out` until the
    /// budget is spent or the book ends. Returns the last id it accounted for (taken, or not
    /// settled), `None` when it accounted for none. Only fold groups require record reads here.
    fn walk(
        &mut self,
        start: u64,
        up: bool,
        budget: &mut Budget,
        out: &mut Vec<RowRef>,
        folds: &mut FoldRead<'_>,
        bounds: Option<(u64, u64)>,
    ) -> Result<Option<u64>, Error> {
        let (lower, upper) = bounds.unwrap_or((self.min_row, self.max_row));
        let mut id = start;
        let mut edge = None;
        let mut looked = 0u32;
        let mut span: Option<Span> = None;
        while id != 0 && id >= lower && id <= upper && budget.rows != 0 && looked < WALK_ENTRIES {
            looked = looked.saturating_add(1);
            if let Some((false, jump)) = self.fold_step(id, up, folds)? {
                let next = jump.unwrap_or_else(|| {
                    if up { id.saturating_add(1) } else { id.saturating_sub(1) }
                });
                edge = Some(if up {
                    next.saturating_sub(1).min(upper)
                } else {
                    next.saturating_add(1).max(lower)
                });
                id = next;
                continue;
            }
            self.stats.walk_entries = self.stats.walk_entries.saturating_add(1);
            if let Some(entry) = self.entry(id) {
                let row = RowRef::of(id, 0, &entry);
                let len = u64::from(entry.len).saturating_add(super::RECORD_OVERHEAD as u64);
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
        Ok(edge)
    }

    /// Returns whether a row is visible under the closed-fold index. A hidden row also returns
    /// the next id at the fold edge so a walk never spends its bound on a 100k-row turn.
    fn fold_step(
        &mut self,
        row_id: u64,
        up: bool,
        folds: &mut FoldRead<'_>,
    ) -> Result<Option<(bool, Option<u64>)>, Error> {
        let Some(fold) = folds.locate(row_id)? else { return Ok(None) };
        if folds.open.contains(&fold.group) || row_id == fold.group {
            return Ok(Some((true, None)));
        }
        self.load_fold_ranges(fold.group, folds)?;
        let ranges = folds.ranges.get(&fold.group).map(Vec::as_slice).unwrap_or(&[]);
        let visible = ranges.iter().any(|(first, last)| (*first..=*last).contains(&row_id));
        if visible {
            Ok(Some((true, None)))
        } else {
            let jump = if up {
                ranges
                    .iter()
                    .find_map(|(first, _)| (*first > row_id).then_some(*first))
                    .or_else(|| fold.last.checked_add(1))
            } else {
                ranges
                    .iter()
                    .rev()
                    .find_map(|(_, last)| (*last < row_id).then_some(*last))
                    .or(Some(fold.group))
            };
            Ok(Some((false, jump)))
        }
    }

    /// Shares one group's metadata read between anchor normalization and every walk direction.
    fn load_fold_ranges(&mut self, group: u64, folds: &mut FoldRead<'_>) -> Result<(), Error> {
        if let std::collections::btree_map::Entry::Vacant(entry) = folds.ranges.entry(group) {
            entry.insert(self.fold_out_ranges(group, &mut folds.validated)?);
        }
        Ok(())
    }

    /// Reads only a group's row to recover its bounded visible `out` ranges.
    fn fold_out_ranges(
        &mut self,
        group: u64,
        validated: &mut BTreeMap<u64, (RowRef, Vec<u8>)>,
    ) -> Result<Vec<(u64, u64)>, Error> {
        let Some(entry) = self.entry(group) else { return Ok(Vec::new()) };
        let row = RowRef::of(group, 0, &entry);
        let Some(bytes) = self.read_row_bytes(&row)? else { return Ok(Vec::new()) };
        let parsed = serde_json::from_slice::<Value>(&bytes);
        // The reply carries this text; it is not read again.
        validated.insert(group, (row, bytes));
        let Ok(value) = parsed else { return Ok(Vec::new()) };
        let Some(out) =
            value.get("body").and_then(|body| body.get("out")).and_then(Value::as_array)
        else {
            return Ok(Vec::new());
        };
        Ok(out
            .iter()
            .filter_map(|range| {
                let pair = range.as_array()?;
                let first = pair.first()?.as_u64()?;
                let last = pair.get(1)?.as_u64()?;
                (first <= last).then_some((first, last))
            })
            .collect())
    }

    /// Moves an anchor in a closed fold's hidden rows to its group. Its search positions the
    /// request's fold cursor, so the walk after it does not search again.
    fn normalize_anchor(&mut self, id: u64, folds: &mut FoldRead<'_>) -> Result<u64, Error> {
        let Some(fold) = folds.locate(id)? else { return Ok(id) };
        if folds.open.contains(&fold.group) || id == fold.group {
            return Ok(id);
        }
        self.load_fold_ranges(fold.group, folds)?;
        let ranges = folds.ranges.get(&fold.group).map(Vec::as_slice).unwrap_or(&[]);
        Ok(if ranges.iter().any(|(first, last)| (*first..=*last).contains(&id)) {
            id
        } else {
            fold.group
        })
    }

    fn read_row_bytes(&mut self, row: &RowRef) -> Result<Option<Vec<u8>>, Error> {
        if row.len == 0 || row.len as usize > crate::row::MAX_ROW_TEXT || row.off < HEADER_LEN_U32 {
            return Ok(None);
        }
        let total = HEADER_LEN.saturating_add(row.len as usize).saturating_add(4);
        let mut bytes = vec![0u8; total];
        let offset = u64::from(row.off).saturating_sub(HEADER_LEN_U64);
        let read = match self.read_segment(row.seg, offset, &mut bytes) {
            Ok(read) => read,
            Err(Error::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
        if read != total {
            return Ok(None);
        }
        let Check::Whole(header) = super::record::check(&bytes) else { return Ok(None) };
        if header.row_id != row.row_id
            || header.rev != row.rev
            || header.len != row.len
            || (row.seq != 0 && header.seq != row.seq)
            || (header.raw_len != 0 && (header.raw_file == 0 || header.raw_file > self.raw_files))
        {
            return Ok(None);
        }
        let text =
            bytes.get(HEADER_LEN..HEADER_LEN.saturating_add(row.len as usize)).unwrap_or_default();
        Ok(Some(text.to_vec()))
    }

    fn record_ok(&mut self, row: &RowRef) -> Result<bool, Error> {
        Ok(self.read_row_bytes(row)?.is_some())
    }

    /// Checks every record of the reply in one read of its rows, which also gives the reply's
    /// text ([`Window::bytes`]). Group rows checked while reading their fold are not read
    /// again: their text is kept from that read. Refused rows leave `rows`.
    fn refuse_rows(&mut self, window: &mut Window, folds: &FoldRead<'_>) -> Result<(), Error> {
        let mut ranges = Vec::new();
        let unchecked;
        let rows = if folds.validated.is_empty() {
            window.rows.as_slice()
        } else {
            unchecked = window
                .rows
                .iter()
                .copied()
                .filter(|row| {
                    folds.validated.get(&row.row_id).map(|(checked, _)| checked) != Some(row)
                })
                .collect::<Vec<_>>();
            unchecked.as_slice()
        };
        self.fill_records(rows, &mut window.bytes, &mut ranges, &mut window.refused)?;
        let refused: std::collections::BTreeSet<_> = window.refused.iter().copied().collect();
        window.rows.retain(|row| !refused.contains(&row.row_id));
        // `ranges` holds the texts of the rows read, in order, without the refused ones.
        let mut filled = ranges.into_iter();
        window.at.clear();
        window.at.reserve(window.rows.len());
        for row in &window.rows {
            let kept = folds.validated.get(&row.row_id).filter(|(checked, _)| checked == row);
            let range = match kept {
                Some((_, text)) => {
                    let start = window.bytes.len();
                    window.bytes.extend_from_slice(text);
                    start..window.bytes.len()
                }
                None => filled.next().ok_or(Error::Corrupt("a checked row has no text"))?,
            };
            window.at.push(range);
        }
        Ok(())
    }

    fn window_of(&self, rows: Vec<RowRef>, lo: u64, hi: u64) -> Window {
        Window {
            // Hidden gaps are accounted for in the flags, never emitted as a cursor:
            // an ask at a hidden row is normalized to its group and would repeat this page.
            lo: rows.first().map_or(lo, |row| row.row_id),
            hi: rows.last().map_or(hi, |row| row.row_id),
            rows,
            has_before: self.min_row != 0 && lo > self.min_row,
            has_after: hi < self.max_row,
            refused: Vec::new(),
            bytes: Vec::new(),
            at: Vec::new(),
        }
    }

    /// The settled rows around `anchor`: at most `rows` of them ([`MAX_ROWS`] at most) and
    /// `max_bytes` of records ([`MAX_FRAME_BYTES`] at most), always at least one when one
    /// exists. Every returned record is checked; damage becomes a named hole.
    pub fn window(
        &mut self,
        anchor: Anchor,
        rows: usize,
        max_bytes: usize,
    ) -> Result<Window, Error> {
        self.read_window(anchor, rows, max_bytes, None, &[])
    }

    /// Checked window read. `open_folds` names folds that are open for this read; closed folds
    /// are stepped over using their group's `out` ranges. `folds` is the sole writer's
    /// current index, whose length excludes any uncommitted suffix after recovery.
    pub fn read_window(
        &mut self,
        anchor: Anchor,
        rows: usize,
        max_bytes: usize,
        folds: Option<&Folds>,
        open_folds: &[u64],
    ) -> Result<Window, Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        let mut budget = Budget {
            rows: Self::bound(rows, MAX_ROWS),
            bytes: Self::bound(max_bytes, MAX_FRAME_BYTES) as u64,
            first_free: true,
            one_read: false,
        };
        let mut out = Vec::with_capacity(budget.rows.min(512));
        let mut fold_read = FoldRead::new(folds, open_folds);
        let mut result = match anchor {
            Anchor::End => {
                let lo =
                    self.walk(self.max_row, false, &mut budget, &mut out, &mut fold_read, None)?;
                out.reverse();
                self.window_of(out, lo.unwrap_or(self.max_row), self.max_row)
            }
            Anchor::Row { id, side: Side::Before } => {
                let start = self.normalize_anchor(id.min(self.max_row), &mut fold_read)?;
                let lo = self.walk(start, false, &mut budget, &mut out, &mut fold_read, None)?;
                out.reverse();
                self.window_of(out, lo.unwrap_or(start), start)
            }
            Anchor::Row { id, side: Side::After } => {
                let start = self.normalize_anchor(id.max(self.min_row), &mut fold_read)?;
                let hi = self.walk(start, true, &mut budget, &mut out, &mut fold_read, None)?;
                self.window_of(out, start, hi.unwrap_or(start))
            }
            Anchor::Row { id, side: Side::Around } => {
                let start = self.normalize_anchor(id.max(self.min_row), &mut fold_read)?;
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
                // Each walk resumes the fold cursor where its rows are, not where the last
                // walk ended, so turning back costs no steps over the rows already walked.
                let at_anchor = fold_read.cursor;
                let mut hi =
                    self.walk(start, true, &mut ahead, &mut after, &mut fold_read, None)?;
                let at_hi = fold_read.cursor;
                if at_anchor.is_some() {
                    fold_read.cursor = at_anchor;
                }
                budget = Budget {
                    rows: kept_rows.saturating_add(ahead.rows),
                    bytes: ahead.bytes,
                    first_free: after.is_empty(),
                    one_read: false,
                };
                let below = start.saturating_sub(1).min(self.max_row);
                let lo = self.walk(below, false, &mut budget, &mut out, &mut fold_read, None)?;
                out.reverse();
                if budget.rows != 0 && budget.bytes != 0 {
                    let next = hi.map_or(start, |hi| hi.saturating_add(1));
                    budget.first_free = false;
                    if at_hi.is_some() {
                        fold_read.cursor = at_hi;
                    }
                    hi = self
                        .walk(next, true, &mut budget, &mut after, &mut fold_read, None)?
                        .or(hi);
                }
                out.append(&mut after);
                self.window_of(out, lo.unwrap_or(start), hi.unwrap_or(start))
            }
        };
        self.refuse_rows(&mut result, &fold_read)?;
        Ok(result)
    }

    /// The checked settled rows just before or just after a row: at most `max_bytes` of
    /// records ([`MAX_PAGE_BYTES`] at most), always at least one when one exists. This
    /// unfolded page also ends at a span boundary so filling its rows takes one read.
    /// The caller continues from `lo` or `hi`; refused records retain their cursor places.
    pub fn page(&mut self, edge: Edge, max_bytes: usize) -> Result<Window, Error> {
        self.read_page(edge, max_bytes, None, None, &[])
    }

    /// Checked page read. When `fold` is present, the named fold is open for this read and the
    /// page is constrained to its group range.
    pub fn read_page(
        &mut self,
        edge: Edge,
        max_bytes: usize,
        fold: Option<u64>,
        folds: Option<&Folds>,
        open_folds: &[u64],
    ) -> Result<Window, Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        if let Some(group) = fold {
            return self.read_fold_page(edge, max_bytes, group, folds, open_folds);
        }
        let mut budget = Budget {
            rows: MAX_ROWS,
            bytes: Self::bound(max_bytes, MAX_PAGE_BYTES) as u64,
            first_free: true,
            one_read: folds.is_none(),
        };
        let mut out = Vec::new();
        let mut fold_read = FoldRead::new(folds, open_folds);
        let mut result = match edge {
            Edge::Before(id) => {
                let id = self.normalize_anchor(id, &mut fold_read)?;
                let start = id.saturating_sub(1).min(self.max_row);
                let lo = self.walk(start, false, &mut budget, &mut out, &mut fold_read, None)?;
                out.reverse();
                self.window_of(out, lo.unwrap_or(id.max(1)), start)
            }
            Edge::After(id) => {
                let id = self.normalize_anchor(id, &mut fold_read)?;
                let start = id.saturating_add(1).max(self.min_row);
                let hi = self.walk(start, true, &mut budget, &mut out, &mut fold_read, None)?;
                self.window_of(out, start, hi.unwrap_or(id.min(self.max_row)))
            }
        };
        self.refuse_rows(&mut result, &fold_read)?;
        Ok(result)
    }

    fn read_fold_page(
        &mut self,
        edge: Edge,
        max_bytes: usize,
        group: u64,
        folds: Option<&Folds>,
        open_folds: &[u64],
    ) -> Result<Window, Error> {
        let mut opened = open_folds.to_vec();
        opened.push(group);
        let mut fold_read = FoldRead::new(folds, &opened);
        // The request's one search; the walk inside the fold reads no other entry.
        let Some(fold) = fold_read.locate(group)?.filter(|entry| entry.group == group) else {
            return Err(Error::InvalidInput("fold is not in folds.idx"));
        };
        let (start, up) = match edge {
            Edge::Before(id) if id == group => (fold.last, false),
            Edge::Before(id) => (id.saturating_sub(1).min(fold.last), false),
            Edge::After(id) if id == group => (fold.group.saturating_add(1), true),
            Edge::After(id) => (id.saturating_add(1).max(fold.group.saturating_add(1)), true),
        };
        let mut budget = Budget {
            rows: MAX_ROWS,
            bytes: Self::bound(max_bytes, MAX_PAGE_BYTES) as u64,
            first_free: true,
            one_read: folds.is_none(),
        };
        let mut rows = Vec::new();
        let edge = self.walk(
            start,
            up,
            &mut budget,
            &mut rows,
            &mut fold_read,
            Some((fold.group.saturating_add(1), fold.last)),
        )?;
        if !up {
            rows.reverse();
        }
        let (lo, hi) =
            if up { (start, edge.unwrap_or(start)) } else { (edge.unwrap_or(start), start) };
        let nonempty = fold.group < fold.last;
        let mut result = Window {
            lo: rows.first().map_or(lo, |row| row.row_id),
            hi: rows.last().map_or(hi, |row| row.row_id),
            has_before: nonempty && lo > fold.group.saturating_add(1),
            has_after: nonempty && hi < fold.last,
            rows,
            refused: Vec::new(),
            bytes: Vec::new(),
            at: Vec::new(),
        };
        self.refuse_rows(&mut result, &fold_read)?;
        Ok(result)
    }

    /// Measures the bytes a resume starts from, without reading a record. Cursors in the
    /// same sparse block share an upper bound; a span across three segments is always over.
    /// At most one closed segment's metadata is read. The actor uses a 1 MiB cap.
    pub fn resume_size(&self, cursor: u64, cap: u64) -> Result<ResumeSize, Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        if cursor >= self.last_seq {
            return Ok(ResumeSize::Within(0));
        }
        let (seg, offset) = self.resume_start(cursor)?;
        let bytes = match self.tail.seg.checked_sub(seg) {
            Some(0) => self.tail.len.checked_sub(offset),
            Some(1) => {
                let len = std::fs::metadata(super::segment_path(&self.rows_dir, seg))?.len();
                len.checked_sub(offset).and_then(|left| {
                    self.tail
                        .len
                        .checked_sub(super::SEGMENT_HEADER_LEN)
                        .and_then(|right| left.checked_add(right))
                })
            }
            Some(_) => return Ok(ResumeSize::Over),
            None => return Err(Error::Corrupt("seq.idx starts after the tail")),
        }
        .ok_or(Error::Corrupt("seq.idx offset is beyond its segment"))?;
        Ok(if bytes <= cap { ResumeSize::Within(bytes) } else { ResumeSize::Over })
    }

    fn resume_start(&self, cursor: u64) -> Result<(u32, u64), Error> {
        let slot = cursor.saturating_add(1) / SEQ_STRIDE;
        if slot == 0 {
            Ok((1, super::SEGMENT_HEADER_LEN))
        } else {
            let (seg, off) = self
                .seqs
                .get(slot)?
                .ok_or(Error::Corrupt("seq.idx has no entry before the cursor"))?;
            Ok((seg, u64::from(off)))
        }
    }

    /// The records after `cursor`, in change order: at most `max_bytes` of record bytes
    /// ([`MAX_FRAME_BYTES`] at most), always at least one when one exists. Starts at the
    /// `seq.idx` entry at or before the cursor, so it reads what was missed (and at most 255
    /// records before it), never the book. A cursor at or past the last seq gets nothing.
    /// Bytes alone bound a resume: it has no row count cap ([`MAX_ROWS`] bounds windows and
    /// pages only).
    pub fn since(&mut self, cursor: u64, max_bytes: usize) -> Result<Since, Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        let mut since = Since {
            rows: Vec::new(),
            cursor: cursor.min(self.last_seq),
            more: false,
            stopped_on_refusal: false,
        };
        if cursor >= self.last_seq {
            return Ok(since);
        }
        let slot = cursor.saturating_add(1) / SEQ_STRIDE;
        let (mut seg, mut offset) = self.resume_start(cursor)?;
        let mut left = Self::bound(max_bytes, MAX_FRAME_BYTES) as u64;
        let mut expected = if slot == 0 { 1 } else { slot.saturating_mul(SEQ_STRIDE) };
        let mut chunk = vec![0u8; RESUME_CHUNK];
        loop {
            let read = match self.read_segment(seg, offset, &mut chunk) {
                Ok(read) => read,
                Err(Error::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {
                    since.stopped_on_refusal = true;
                    return Ok(since);
                }
                Err(error) => return Err(error),
            };
            if read == 0 {
                // The end of a segment: the next record starts the next one.
                if seg >= self.tail.seg {
                    since.stopped_on_refusal = expected <= self.last_seq;
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
                let Some(header) = Header::parse(rest) else {
                    since.stopped_on_refusal = true;
                    return Ok(since);
                };
                let row = RowRef {
                    row_id: header.row_id,
                    rev: header.rev,
                    seq: header.seq,
                    seg,
                    off: u32::try_from(offset.saturating_add(HEADER_LEN_U64))
                        .map_err(|_| Error::Corrupt("a segment is past 4 GiB"))?,
                    len: header.len,
                    raw: RawRange {
                        file: header.raw_file,
                        off: header.raw_off,
                        len: header.raw_len,
                    },
                };
                let valid = if rest.len() >= header.record_len() {
                    matches!(super::record::check(rest), Check::Whole(_))
                        && (header.raw_len == 0
                            || (header.raw_file != 0 && header.raw_file <= self.raw_files))
                } else {
                    self.record_ok(&row)?
                };
                if !valid || header.seq != expected {
                    since.stopped_on_refusal = true;
                    return Ok(since);
                }
                expected = expected.saturating_add(1);
                if header.seq > cursor {
                    let len = header.record_len() as u64;
                    let full = len > left;
                    if full && !since.rows.is_empty() {
                        since.more = true;
                        return Ok(since);
                    }
                    since.rows.push(row);
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
                since.stopped_on_refusal = true;
                return Ok(since);
            }
        }
    }

    /// Reads the row texts of `rows` out of the segments. `buf` (cleared first) receives the
    /// segment bytes and `at[i]` is where row `i`'s text lies in it; the caller copies those
    /// slices into its frame. Neighbouring records in one segment share a read; folded pages
    /// can require several bounded spans. Returns the reads made. A window or page already
    /// carries its rows' text ([`Window::bytes`]); this is for rows from elsewhere.
    ///
    /// Each row's record header is checked against the row asked for, so an index entry that
    /// does not match its record is [`Error::CorruptRow`], never another row's text.
    pub fn fill(
        &mut self,
        rows: &[RowRef],
        buf: &mut Vec<u8>,
        at: &mut Vec<Range<usize>>,
    ) -> Result<u32, Error> {
        let mut refused = Vec::new();
        let reads = self.fill_checked(rows, buf, at, &mut refused)?;
        if let Some(row_id) = refused.first() {
            return Err(Error::CorruptRow { row_id: *row_id, reason: "a record was refused" });
        }
        Ok(reads)
    }

    /// Copies valid row text in bounded runs and names damaged records as holes.
    /// `at` has a range for each valid row, in input order; `refused` has the omitted ids.
    /// A missing segment, short record, bad header or bad CRC refuses only that record.
    pub fn fill_checked(
        &mut self,
        rows: &[RowRef],
        buf: &mut Vec<u8>,
        at: &mut Vec<Range<usize>>,
        refused: &mut Vec<u64>,
    ) -> Result<u32, Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        buf.clear();
        at.clear();
        refused.clear();
        let mut reads = 0u32;
        let mut rest = rows;
        while let Some(first) = rest.first() {
            if first.len == 0
                || first.len as usize > crate::row::MAX_ROW_TEXT
                || first.off < HEADER_LEN_U32
            {
                refused.push(first.row_id);
                rest = rest.get(1..).unwrap_or_default();
                continue;
            }
            let mut span = Span::of(first);
            let mut count = 1usize;
            while let Some(joined) = rest
                .get(count)
                .filter(|row| {
                    row.len != 0
                        && row.len as usize <= crate::row::MAX_ROW_TEXT
                        && row.off >= HEADER_LEN_U32
                })
                .and_then(|row| span.with(row))
            {
                span = joined;
                count = count.saturating_add(1);
            }
            let (run, after) = rest.split_at_checked(count).unwrap_or((rest, &[]));
            rest = after;
            let base = self.read_span(span, buf)?;
            reads = reads.saturating_add(1);
            for row in run {
                match self.checked_text(buf, base, span.lo, row) {
                    Some(text) => at.push(text),
                    None => refused.push(row.row_id),
                }
            }
        }
        Ok(reads)
    }

    /// [`Log::fill_checked`] for a reply's own rows: a read covers only records that lie back
    /// to back in a segment, in whatever row order they were written, so it holds no other
    /// record's bytes (a closed fold's hidden rows, a row's old revision). The reply's bytes
    /// read are its records' bytes. `at` and `refused` are in input order.
    fn fill_records(
        &mut self,
        rows: &[RowRef],
        buf: &mut Vec<u8>,
        at: &mut Vec<Range<usize>>,
        refused: &mut Vec<u64>,
    ) -> Result<u32, Error> {
        if self.broken {
            return Err(Error::Stopped);
        }
        buf.clear();
        at.clear();
        refused.clear();
        let readable = |row: &RowRef| {
            row.len != 0
                && row.len as usize <= crate::row::MAX_ROW_TEXT
                && row.off >= HEADER_LEN_U32
        };
        let mut texts: Vec<Option<Range<usize>>> = vec![None; rows.len()];
        let mut order: Vec<(usize, &RowRef)> =
            rows.iter().enumerate().filter(|(_, row)| readable(*row)).collect();
        order.sort_by_key(|(_, row)| (row.seg, row.off));
        let mut reads = 0u32;
        let mut rest = order.as_slice();
        while let Some((_, first)) = rest.first() {
            let mut span = Span::of(first);
            let mut count = 1usize;
            while let Some(joined) = rest.get(count).and_then(|(_, row)| span.followed_by(row)) {
                span = joined;
                count = count.saturating_add(1);
            }
            let (run, after) = rest.split_at_checked(count).unwrap_or((rest, &[]));
            rest = after;
            let base = self.read_span(span, buf)?;
            reads = reads.saturating_add(1);
            for (index, row) in run {
                if let Some(slot) = texts.get_mut(*index) {
                    *slot = self.checked_text(buf, base, span.lo, row);
                }
            }
        }
        for (row, text) in rows.iter().zip(texts) {
            match text {
                Some(text) => at.push(text),
                None => refused.push(row.row_id),
            }
        }
        Ok(reads)
    }

    /// Appends a span's segment bytes to `buf` and returns where they start. A missing
    /// segment or a short read leaves fewer bytes, which refuses the records they lack.
    fn read_span(&mut self, span: Span, buf: &mut Vec<u8>) -> Result<usize, Error> {
        let base = buf.len();
        let len = usize::try_from(span.hi.saturating_sub(span.lo)).unwrap_or(usize::MAX);
        buf.resize(base.saturating_add(len), 0);
        let read = match buf.get_mut(base..) {
            Some(space) => match self.read_segment(span.seg, span.lo, space) {
                Ok(read) => read,
                Err(Error::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => 0,
                Err(error) => return Err(error),
            },
            None => 0,
        };
        buf.truncate(base.saturating_add(read));
        Ok(base)
    }

    /// Where `row`'s text lies in `buf`, whose byte `base` holds segment offset `lo`, when its
    /// record there is whole (header and CRC) and is the record asked for.
    fn checked_text(&self, buf: &[u8], base: usize, lo: u64, row: &RowRef) -> Option<Range<usize>> {
        let header_at =
            usize::try_from(u64::from(row.off).saturating_sub(HEADER_LEN_U64).saturating_sub(lo))
                .unwrap_or(usize::MAX)
                .saturating_add(base);
        let record_end = header_at.checked_add(HEADER_LEN + row.len as usize + 4);
        let checked = record_end.and_then(|end| buf.get(header_at..end)).map(super::record::check);
        let same = checked.is_some_and(|check| {
            let Check::Whole(header) = check else { return false };
            header.row_id == row.row_id
                && header.rev == row.rev
                && header.len == row.len
                && (row.seq == 0 || row.seq == header.seq)
                && (header.raw_len == 0
                    || (header.raw_file != 0 && header.raw_file <= self.raw_files))
        });
        let text = header_at.saturating_add(HEADER_LEN);
        same.then_some(text..text.saturating_add(row.len as usize))
    }
}
