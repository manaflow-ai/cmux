//! One directory page and one entry-page cache per request. A short bucket
//! needs one entry page; a long bucket needs at most ceil(log2(pages)) + 1
//! search pages, then one page per 127 entries walked. Equal-activity cursors
//! compare decoded row keys by binary search, never scan an entire tie.
use super::{
    ENTRIES_PER_PAGE, ENTRY_BYTES, Entry, FAMILY_KIND, FORK_KIND, MAX_DEPTH, PAGE_BYTES,
    SLOTS_PER_PAGE, Table, invalid, key_fingerprint, read_u32,
};
use crate::index::snapshot::kin_read::{KinIo, KinRequest};
use crate::index::snapshot::read::Frame;
use crate::index::snapshot::{DiskSnapshot, HEADER_BYTES, TRAILER_BYTES};
use crate::index::{SortKey, Summary};
use std::io;
use std::sync::Arc;

pub(in crate::index::snapshot) enum Failure {
    Budget,
    Unavailable,
    Invalid(io::Error),
}
impl From<io::Error> for Failure {
    fn from(error: io::Error) -> Self {
        Self::Invalid(error)
    }
}

#[derive(Clone, Copy)]
enum Phase {
    Directory,
    Search,
    Walk,
}

pub(in crate::index::snapshot) struct Cursor<'a> {
    disk: &'a DiskSnapshot,
    table: &'a Table,
    fingerprint: (u64, u32),
    cold_before: u64,
    position_offset: Option<u64>,
    budget: usize,
    start: u64,
    end: u64,
    at: u64,
    slot: u32,
    page: Option<(u64, [u8; PAGE_BYTES])>,
    row_cache: Option<(Entry, Arc<Summary>)>,
    pub io: KinIo,
}

impl<'a> Cursor<'a> {
    pub fn new(disk: &'a DiskSnapshot, table: &'a Table, request: &KinRequest<'_>) -> Self {
        let fingerprint = key_fingerprint(request.root, FAMILY_KIND);
        let slot = slot_for(fingerprint.0, table.header.slots);
        Self {
            disk,
            table,
            fingerprint,
            cold_before: request.cold_before,
            budget: request.physical_bytes.min(super::super::PAGE_BYTES),
            start: 0,
            end: 0,
            at: 0,
            slot,
            page: None,
            row_cache: None,
            io: KinIo {
                bytes: request.position.map_or(0, |position| position.bytes_read),
                ..KinIo::default()
            },
            position_offset: request.position.map(|position| position.offset),
        }
    }

    fn charge(&mut self, bytes: usize) -> Result<(), Failure> {
        let total = self.io.bytes.checked_add(bytes).ok_or(Failure::Budget)?;
        if total > self.budget {
            return Err(Failure::Budget);
        }
        self.io.bytes = total;
        Ok(())
    }

    fn page(&mut self, index: u64, phase: Phase) -> Result<&[u8; PAGE_BYTES], Failure> {
        if self.page.as_ref().is_none_or(|(cached, _)| *cached != index) {
            self.charge(PAGE_BYTES)?;
            match phase {
                Phase::Directory => self.io.directory_pages += 1,
                Phase::Search => self.io.search_pages += 1,
                Phase::Walk => self.io.walk_pages += 1,
            }
            let bytes = self.table.read_page(index).ok_or(Failure::Unavailable)?;
            self.page = Some((index, bytes));
        }
        self.page.as_ref().map(|(_, bytes)| bytes).ok_or(Failure::Unavailable)
    }

    pub fn seek(&mut self, request: &KinRequest<'_>) -> Result<(), Failure> {
        if self.table.header.entries == 0 {
            return Ok(());
        }
        let slot = self.slot as usize;
        let page = self.page((slot / SLOTS_PER_PAGE) as u64, Phase::Directory)?;
        let at = (slot % SLOTS_PER_PAGE) * 8;
        let bytes = page.get(at..at + 8).ok_or_else(|| invalid("kin slot offset"))?;
        let (start, len) = bytes.split_at(4);
        let start = u64::from(read_u32(start)?);
        let len = u64::from(read_u32(len)?);
        self.start = start;
        self.end = self.start.checked_add(len).ok_or_else(|| invalid("kin slot overflow"))?;
        let width = ENTRIES_PER_PAGE as u64;
        if self.end > self.table.header.packed_entries
            || (len > 0 && len <= width && self.start / width != (self.end - 1) / width)
            || (len > width && !self.start.is_multiple_of(width))
        {
            return Err(invalid("kin slot extent or alignment").into());
        }
        self.at = self.start;
        if len == 0 {
            return Ok(());
        }
        let mut left = self.start / width;
        let mut right = (self.end - 1) / width + 1;
        while left < right {
            let middle = left + (right - left) / 2;
            let last = ((middle + 1) * width).min(self.end) - 1;
            let entry = self.entry(last, Phase::Search)?;
            if self.before(entry, request)? {
                left = middle + 1;
            } else {
                right = middle;
            }
        }
        let mut low = (left * width).max(self.start).min(self.end);
        let mut high = ((left + 1) * width).min(self.end);
        while low < high {
            let middle = low + (high - low) / 2;
            let entry = self.entry(middle, Phase::Search)?;
            if self.before(entry, request)? {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        self.at = low;
        Ok(())
    }

    fn before(&mut self, entry: Entry, request: &KinRequest<'_>) -> Result<bool, Failure> {
        if entry.hash != self.fingerprint.0 {
            return Ok(entry.hash < self.fingerprint.0);
        }
        self.check_fingerprint(entry)?;
        if entry.activity >= self.cold_before {
            return Ok(true);
        }
        if let Some(offset) = self.position_offset {
            return Ok(entry.offset < offset);
        }
        let Some(after) = request.after else {
            return Ok(false);
        };
        if entry.activity != after.last_activity {
            return Ok(entry.activity > after.last_activity);
        }
        let row = self.row(entry)?;
        let key = SortKey::of(row.as_ref());
        Ok(key < *after || (!request.inclusive && key == *after))
    }

    fn entry(&mut self, position: u64, phase: Phase) -> Result<Entry, Failure> {
        if position < self.start || position >= self.end {
            return Err(invalid("kin entry position").into());
        }
        let width = ENTRIES_PER_PAGE as u64;
        let directory_pages = u64::from(self.table.header.directory_pages);
        let data_end = self.disk.head.data_end;
        let slot = self.slot;
        let slots = self.table.header.slots;
        let start = self.start.max(position / width * width);
        let end = self.end.min((position / width + 1) * width);
        let page = self.page(directory_pages + position / width, phase)?;
        let decode = |index: u64| -> io::Result<Entry> {
            let at = (index % width) as usize * ENTRY_BYTES;
            let entry = Entry::decode(
                page.get(at..at + ENTRY_BYTES).ok_or_else(|| invalid("kin entry bytes"))?,
            )?;
            validate(entry, data_end)?;
            if slot_for(entry.hash, slots) != slot {
                return Err(invalid("kin entry slot"));
            }
            Ok(entry)
        };
        let selected = decode(position)?;
        // Validate the inspected boundary, without scanning unrelated entries
        // merely because their hashes share the request's bucket.
        if position > start {
            ordered(decode(position - 1)?, selected)?;
        }
        if position + 1 < end {
            ordered(selected, decode(position + 1)?)?;
        }
        Ok(selected)
    }

    pub fn row(&mut self, entry: Entry) -> Result<Arc<Summary>, Failure> {
        if let Some((cached, row)) = &self.row_cache
            && cached.offset == entry.offset
            && cached.len == entry.len
            && cached.activity == entry.activity
        {
            return Ok(row.clone());
        }
        self.charge(usize::from(entry.len))?;
        self.io.frames += 1;
        let bytes = self.disk.read_range(entry.offset, usize::from(entry.len))?;
        let mut input = bytes.as_slice();
        let row = match self.disk.read_frame(&mut input)? {
            Frame::Row(row, len)
                if len == usize::from(entry.len)
                    && input.is_empty()
                    && row.last_activity == entry.activity =>
            {
                row
            }
            _ => return Err(invalid("kin referenced frame").into()),
        };
        self.row_cache = Some((entry, row.clone()));
        Ok(row)
    }

    pub fn has_before(&mut self) -> Result<bool, Failure> {
        if self.at <= self.start {
            return Ok(false);
        }
        let entry = self.entry(self.at - 1, Phase::Walk)?;
        if entry.hash != self.fingerprint.0 || entry.activity >= self.cold_before {
            return Ok(false);
        }
        if let Some(offset) = self.position_offset {
            return Ok(entry.offset < offset);
        }
        self.check_fingerprint(entry)?;
        Ok(true)
    }

    pub fn next(&mut self) -> Result<Option<Entry>, Failure> {
        if self.at >= self.end {
            return Ok(None);
        }
        let entry = self.entry(self.at, Phase::Walk)?;
        self.at += 1;
        if entry.hash != self.fingerprint.0 {
            return Ok(None);
        }
        self.check_fingerprint(entry)?;
        Ok(Some(entry))
    }

    fn check_fingerprint(&self, entry: Entry) -> Result<(), Failure> {
        // A true hash collision and a damaged check are indistinguishable.
        // Sacrifice the accelerator in either case; never report no kin on
        // evidence that might instead be a damaged fingerprint.
        if entry.check != self.fingerprint.1 || entry.kind != FAMILY_KIND {
            return Err(invalid("kin ancestor fingerprint").into());
        }
        Ok(())
    }
}

fn slot_for(hash: u64, slots: u32) -> u32 {
    if slots == 1 { 0 } else { (hash >> (64 - slots.trailing_zeros())) as u32 }
}

fn validate(entry: Entry, data_end: u64) -> io::Result<()> {
    if !matches!(entry.kind, FAMILY_KIND | FORK_KIND)
        || !(1..=MAX_DEPTH).contains(&entry.depth)
        || entry.offset < HEADER_BYTES as u64
        || entry.len < 12
        || usize::from(entry.len) > crate::index::MAX_INDEX_RECORD_BYTES + TRAILER_BYTES
        || entry.offset.checked_add(u64::from(entry.len)).is_none_or(|end| end > data_end)
    {
        return Err(invalid("kin entry extent, kind or depth"));
    }
    Ok(())
}

fn ordered(left: Entry, right: Entry) -> io::Result<()> {
    if (left.hash, left.offset) > (right.hash, right.offset)
        || (left.hash == right.hash && left.activity < right.activity)
    {
        return Err(invalid("kin entry order"));
    }
    Ok(())
}
