//! The phone's history of terminal rows the Mac already delivered, so a
//! scroll back over them costs no round trip and no byte on the link.
//!
//! Before it, every older-row fetch was a reattach whose replay re-sent every
//! row the phone held (the screen, rows streamed past, earlier replays) along
//! with the older chunk: 34 to 67% of each replay's rows had been sent before
//! (`claudepaged`, #50148). This store keeps the delivered rows, so a fetch
//! asks the Mac only for the rows above the oldest one held
//! (`replay_history_start` / `replay_history_rows`, [`DeliveredHistory::next_fetch`])
//! and the rows held are fed locally from here.
//!
//! Rows are numbered from the Mac's oldest history row (0). The store holds
//! one contiguous run of them, at most `cap_bytes` of row bytes: rows streamed
//! below it push the oldest out; pages fetched above it stop at the cap (past
//! it the window of #43189 takes over, as before).
//!
//! The row format sits behind [`HistoryRow`]: today a row is the VT bytes the
//! Mac wrote for it ([`VtRow`]); the projection crate's rows
//! (`cmux-terminal-projection`, #49901) implement it the same way once that
//! crate lands, and the store, its cap and its fetch plan stay.

use std::collections::VecDeque;
use std::sync::{Mutex, MutexGuard, PoisonError};

/// One terminal row as the store holds it.
pub trait HistoryRow: Sized {
    /// The row from the VT bytes the Mac wrote for it (no line ending).
    fn from_vt(bytes: &[u8]) -> Self;
    /// Appends the row's VT bytes (no line ending) to `out`.
    fn write_vt(&self, out: &mut Vec<u8>);
    /// The bytes the row costs against the cap.
    fn cost(&self) -> usize;
}

/// A row as the Mac's VT bytes, in one boxed slice (no spare capacity).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VtRow(Box<[u8]>);

impl HistoryRow for VtRow {
    fn from_vt(bytes: &[u8]) -> Self {
        Self(bytes.into())
    }

    fn write_vt(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.0);
    }

    fn cost(&self) -> usize {
        self.0.len()
    }
}

/// Rows to ask the Mac for: `rows` rows from row `start`, all of them never
/// delivered (they end at the oldest row held).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct HistoryFetch {
    pub start: u64,
    pub rows: u32,
}

/// The delivered rows, one contiguous run, capped in bytes.
#[derive(Debug)]
pub struct DeliveredHistory<R: HistoryRow> {
    rows: VecDeque<R>,
    /// The number of `rows[0]`.
    first: u64,
    bytes: usize,
    cap_bytes: usize,
}

impl<R: HistoryRow> DeliveredHistory<R> {
    pub fn new(cap_bytes: usize) -> Self {
        Self { rows: VecDeque::new(), first: 0, bytes: 0, cap_bytes }
    }

    /// The oldest row held, or `None` when empty.
    pub fn first(&self) -> Option<u64> {
        (!self.rows.is_empty()).then_some(self.first)
    }

    /// One past the newest row held.
    pub fn end(&self) -> u64 {
        self.first + self.rows.len() as u64
    }

    pub fn len(&self) -> usize {
        self.rows.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    pub fn bytes(&self) -> usize {
        self.bytes
    }

    /// Row `number` arrived below the rows held (streamed past the screen,
    /// or the screen of an attach). A row already held is replaced; one past
    /// a gap starts the run over from it. The oldest rows go past the cap.
    pub fn push_newest(&mut self, number: u64, row: R) {
        if self.rows.is_empty() || number > self.end() || number < self.first {
            self.clear();
            self.first = number;
        } else if number < self.end() {
            // A redraw of a row held (the last screen row, say): drop it and
            // the rows below it, the newer write wins.
            let keep = (number - self.first) as usize;
            for dropped in self.rows.drain(keep..) {
                self.bytes -= dropped.cost();
            }
        }
        self.bytes += row.cost();
        self.rows.push_back(row);
        while self.bytes > self.cap_bytes && self.rows.len() > 1 {
            if let Some(dropped) = self.rows.pop_front() {
                self.bytes -= dropped.cost();
                self.first += 1;
            }
        }
    }

    /// The rows to fetch next, at most `chunk`, right above the oldest held:
    /// `None` when the store holds row 0 (line 1), is empty, or is full.
    pub fn next_fetch(&self, chunk: u32) -> Option<HistoryFetch> {
        let first = self.first()?;
        if first == 0 || chunk == 0 || self.bytes >= self.cap_bytes {
            return None;
        }
        let start = first.saturating_sub(u64::from(chunk));
        Some(HistoryFetch { start, rows: (first - start) as u32 })
    }

    /// A fetched page, rows from `start`, goes above the oldest row held.
    /// Rows the store holds already are skipped (never stored twice), a page
    /// that does not reach the oldest row is refused (it would leave a gap),
    /// and it stops at the cap. Returns the rows taken.
    pub fn prepend_older(&mut self, start: u64, page: Vec<R>) -> usize {
        let Some(first) = self.first() else {
            // Nothing held: the page is the run.
            let mut taken = 0;
            for (offset, row) in page.into_iter().enumerate() {
                if self.bytes + row.cost() > self.cap_bytes && taken > 0 {
                    break;
                }
                self.push_newest(start + offset as u64, row);
                taken += 1;
            }
            return taken;
        };
        let page_end = start + page.len() as u64;
        if page_end < first || start >= first {
            return 0;
        }
        let useful = (first - start) as usize;
        let mut taken = 0;
        for row in page.into_iter().take(useful).rev() {
            if self.bytes + row.cost() > self.cap_bytes {
                break;
            }
            self.bytes += row.cost();
            self.rows.push_front(row);
            self.first -= 1;
            taken += 1;
        }
        taken
    }

    /// The rows held from row `from` (clamped to the run), as VT: each row
    /// then CR LF, to feed a terminal after a reset.
    pub fn vt_from(&self, from: u64) -> Vec<u8> {
        let skip = from.saturating_sub(self.first).min(self.rows.len() as u64) as usize;
        let mut out = Vec::with_capacity(self.bytes + 2 * self.rows.len());
        for row in self.rows.iter().skip(skip) {
            row.write_vt(&mut out);
            out.extend_from_slice(b"\r\n");
        }
        out
    }

    pub fn clear(&mut self) {
        self.rows.clear();
        self.bytes = 0;
    }
}

/// The byte cap of a phone terminal's delivered rows: the phone's Ghostty
/// scrollback cap (`scrollback-limit-bytes`, 8 MiB).
pub const DEFAULT_HISTORY_CAP_BYTES: u64 = 8 * 1024 * 1024;

/// One phone terminal's delivered rows (Swift's handle on
/// [`DeliveredHistory`] of [`VtRow`]).
#[derive(uniffi::Object)]
pub struct TerminalDeliveredHistory {
    store: Mutex<DeliveredHistory<VtRow>>,
}

impl TerminalDeliveredHistory {
    fn store(&self) -> MutexGuard<'_, DeliveredHistory<VtRow>> {
        self.store.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl TerminalDeliveredHistory {
    /// `cap_bytes`: 0 for [`DEFAULT_HISTORY_CAP_BYTES`].
    #[uniffi::constructor]
    pub fn new(cap_bytes: u64) -> Self {
        let cap = if cap_bytes == 0 { DEFAULT_HISTORY_CAP_BYTES } else { cap_bytes };
        Self { store: Mutex::new(DeliveredHistory::new(usize::try_from(cap).unwrap_or(usize::MAX))) }
    }

    /// Rows delivered below the rows held, from row `first`.
    pub fn push_newest(&self, first: u64, rows: Vec<Vec<u8>>) {
        let mut store = self.store();
        for (offset, row) in rows.iter().enumerate() {
            store.push_newest(first + offset as u64, VtRow::from_vt(row));
        }
    }

    /// The never-delivered rows to ask the Mac for next, at most `chunk`.
    pub fn next_fetch(&self, chunk: u32) -> Option<HistoryFetch> {
        self.store().next_fetch(chunk)
    }

    /// A fetched page above the oldest row held; returns the rows taken.
    pub fn prepend_older(&self, start: u64, rows: Vec<Vec<u8>>) -> u32 {
        let page = rows.iter().map(|row| VtRow::from_vt(row)).collect();
        u32::try_from(self.store().prepend_older(start, page)).unwrap_or(u32::MAX)
    }

    /// The rows held from row `from`, as VT (each row then CR LF).
    pub fn vt_from(&self, from: u64) -> Vec<u8> {
        self.store().vt_from(from)
    }

    pub fn first_row(&self) -> Option<u64> {
        self.store().first()
    }

    pub fn row_count(&self) -> u64 {
        self.store().len() as u64
    }

    pub fn held_bytes(&self) -> u64 {
        self.store().bytes() as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(number: u64) -> VtRow {
        VtRow::from_vt(format!("\x1b[32mrow {number}\x1b[0m").as_bytes())
    }

    fn rows(range: std::ops::Range<u64>) -> Vec<VtRow> {
        range.map(row).collect()
    }

    fn streamed(range: std::ops::Range<u64>, cap: usize) -> DeliveredHistory<VtRow> {
        let mut store = DeliveredHistory::new(cap);
        for number in range {
            store.push_newest(number, row(number));
        }
        store
    }

    #[test]
    fn fetches_only_rows_above_the_oldest_held() {
        // The screen and 300 streamed rows of a 12,000-row history.
        let store = streamed(11_700..12_000, 1 << 20);
        assert_eq!(store.next_fetch(2_000), Some(HistoryFetch { start: 9_700, rows: 2_000 }));
        let near_top = streamed(1_500..1_600, 1 << 20);
        assert_eq!(near_top.next_fetch(2_000), Some(HistoryFetch { start: 0, rows: 1_500 }));
        assert_eq!(streamed(0..10, 1 << 20).next_fetch(2_000), None, "line 1 held");
        assert_eq!(DeliveredHistory::<VtRow>::new(1 << 20).next_fetch(2_000), None);
    }

    #[test]
    fn a_page_goes_above_the_oldest_row_and_a_scroll_back_resends_nothing() {
        let mut store = streamed(11_700..12_000, 1 << 20);
        let mut fetched_rows = 0u64;
        while let Some(fetch) = store.next_fetch(2_000) {
            fetched_rows += u64::from(fetch.rows);
            let taken =
                store.prepend_older(fetch.start, rows(fetch.start..fetch.start + u64::from(fetch.rows)));
            assert_eq!(taken, fetch.rows as usize);
        }
        assert_eq!(fetched_rows, 11_700, "each row above the screen once, none twice");
        assert_eq!(store.first(), Some(0));
        assert_eq!(store.end(), 12_000);
        let vt = store.vt_from(0);
        assert!(vt.starts_with(b"\x1b[32mrow 0\x1b[0m\r\n\x1b[32mrow 1\x1b[0m\r\n"));
        assert!(vt.ends_with(b"row 11999\x1b[0m\r\n"));
    }

    #[test]
    fn rows_held_already_are_never_stored_twice_and_gaps_are_refused() {
        let mut store = streamed(100..200, 1 << 20);
        // Overlaps the held rows by 50: only 50..100 are new.
        assert_eq!(store.prepend_older(50, rows(50..150)), 50);
        assert_eq!((store.first(), store.len()), (Some(50), 150));
        // Ends above the oldest row: a gap.
        assert_eq!(store.prepend_older(0, rows(0..10)), 0);
        // Wholly inside the run.
        assert_eq!(store.prepend_older(60, rows(60..70)), 0);
        assert_eq!(store.len(), 150);
    }

    #[test]
    fn the_cap_drops_the_oldest_rows_as_new_ones_stream_and_stops_pages() {
        let cost = row(1_000).cost();
        let mut store = streamed(1_000..1_100, cost * 50);
        assert!(store.bytes() <= cost * 50);
        assert_eq!(store.end(), 1_100);
        assert_eq!(store.first(), Some(1_050));
        assert_eq!(store.next_fetch(2_000), None, "full: the window takes over");

        let mut room = streamed(1_000..1_010, cost * 20);
        assert_eq!(room.prepend_older(990, rows(990..1_000)), 10);
        assert_eq!(room.prepend_older(980, rows(980..990)), 0, "at the cap");
        assert!(room.bytes() <= cost * 20);
    }

    #[test]
    fn a_redrawn_row_replaces_the_row_and_a_gap_restarts_the_run() {
        let mut store = streamed(10..20, 1 << 20);
        store.push_newest(19, VtRow::from_vt(b"redrawn"));
        assert_eq!(store.len(), 10);
        assert!(store.vt_from(19).starts_with(b"redrawn\r\n"));
        store.push_newest(40, row(40));
        assert_eq!((store.first(), store.len()), (Some(40), 1));
    }

    #[test]
    fn rows_are_stored_compactly() {
        let store = streamed(0..12_000, usize::MAX);
        let row_bytes: usize = (0..12_000).map(|n| row(n).cost()).sum();
        assert_eq!(store.bytes(), row_bytes);
        assert_eq!(
            std::mem::size_of::<VtRow>(),
            2 * std::mem::size_of::<usize>(),
            "a boxed slice: pointer and length"
        );
    }

    #[test]
    fn the_handle_round_trips_rows() {
        let history = TerminalDeliveredHistory::new(0);
        history.push_newest(500, vec![b"a".to_vec(), b"b".to_vec()]);
        assert_eq!(history.next_fetch(100), Some(HistoryFetch { start: 400, rows: 100 }));
        assert_eq!(history.prepend_older(400, (400..500).map(|n| n.to_string().into_bytes()).collect()), 100);
        assert_eq!(history.first_row(), Some(400));
        assert_eq!(history.row_count(), 102);
        assert!(history.vt_from(499).starts_with(b"499\r\na\r\nb\r\n"));
    }
}
