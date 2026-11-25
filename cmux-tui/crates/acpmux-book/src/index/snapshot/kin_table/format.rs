//! Streaming slot/page layout. Only one directory page, one entry page and
//! 128 lookahead entries are resident, irrespective of table size.
use super::build::SortedEntries;
use super::{
    Binding, ENTRIES_PER_PAGE, ENTRY_BYTES, Entry, PAGE_BYTES, SLOTS_PER_PAGE, TABLE_HEADER_BYTES,
    TableHeader, invalid, read_u32, read_u64,
};
use std::fs::OpenOptions;
use std::io::{self, Seek, SeekFrom, Write};
use std::path::Path;
const MAGIC: &[u8; 8] = b"ACKIN001";
const VERSION: u32 = 1;

fn slot_for(hash: u64, slots: u32) -> u32 {
    if slots == 1 { 0 } else { (hash >> (64 - slots.trailing_zeros())) as u32 }
}

pub(super) fn write_table(
    path: &Path,
    binding: Binding,
    mut entries: SortedEntries,
) -> io::Result<u64> {
    let count = entries.count;
    let slots = u32::try_from(
        count
            .div_ceil(64)
            .max(1)
            .checked_next_power_of_two()
            .ok_or_else(|| invalid("kin slot count overflow"))?,
    )
    .map_err(|_| invalid("kin slot count overflow"))?;
    let directory_pages = if count == 0 { 0 } else { slots.div_ceil(SLOTS_PER_PAGE as u32) };
    // create_new prevents an optional accelerator failure from truncating an
    // unrelated file. The compactor owns and cleans this exact staging name.
    let mut file = OpenOptions::new().create_new(true).write(true).open(path)?;
    let result = (|| {
        file.write_all(&[0; TABLE_HEADER_BYTES])?;
        let mut output = Pages {
            file: &mut file,
            directory: [0; PAGE_BYTES],
            page: [0; PAGE_BYTES],
            packed: 0,
            directory_page: 0,
            used: 0,
            data_start: (1 + u64::from(directory_pages)) * PAGE_BYTES as u64,
        };
        output.file.seek(SeekFrom::Start(output.data_start))?;
        let mut next = entries.next()?;
        let mut emitted = 0;
        for slot in 0..slots {
            // Bounded lookahead distinguishes a one-page bucket from a long
            // bucket. A large bucket is streamed after these first 128 entries.
            let mut bucket = Vec::with_capacity(ENTRIES_PER_PAGE + 1);
            while next.is_some_and(|entry| slot_for(entry.hash, slots) == slot)
                && bucket.len() <= ENTRIES_PER_PAGE
            {
                if let Some(entry) = next {
                    bucket.push(entry);
                }
                next = entries.next()?;
            }
            if !bucket.is_empty()
                && (bucket.len() > ENTRIES_PER_PAGE
                    || output.used + bucket.len() > ENTRIES_PER_PAGE)
            {
                output.pad()?;
            }
            let start = output.packed;
            let mut len = 0u64;
            for entry in bucket {
                output.push(entry)?;
                len += 1;
            }
            while next.is_some_and(|entry| slot_for(entry.hash, slots) == slot) {
                if let Some(entry) = next {
                    output.push(entry)?;
                    len += 1;
                }
                next = entries.next()?;
            }
            emitted += len;
            if count != 0 {
                output.slot(slot, start, len)?;
            }
        }
        if next.is_some() || emitted != count {
            return Err(invalid("kin sorted entry count"));
        }
        let packed = output.packed;
        if output.used != 0 {
            output.flush_page()?;
        }
        if count != 0 && !(slots as usize).is_multiple_of(SLOTS_PER_PAGE) {
            output.flush_directory()?;
        }
        let length = (1 + u64::from(directory_pages) + packed.div_ceil(ENTRIES_PER_PAGE as u64))
            * PAGE_BYTES as u64;
        let header = encode_header(
            binding,
            TableHeader { entries: count, slots, directory_pages, packed_entries: packed },
        );
        file.seek(SeekFrom::Start(0))?;
        file.write_all(&header)?;
        file.sync_all()?;
        Ok(length)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(path);
    }
    result
}

struct Pages<'a> {
    file: &'a mut std::fs::File,
    directory: [u8; PAGE_BYTES],
    page: [u8; PAGE_BYTES],
    packed: u64,
    directory_page: u64,
    used: usize,
    data_start: u64,
}
impl Pages<'_> {
    fn push(&mut self, entry: Entry) -> io::Result<()> {
        if self.packed >= u64::from(u32::MAX) {
            return Err(invalid("kin packed entry overflow"));
        }
        entry.encode(
            self.page
                .get_mut(self.used * ENTRY_BYTES..(self.used + 1) * ENTRY_BYTES)
                .ok_or_else(|| invalid("kin entry page offset"))?,
        )?;
        self.used += 1;
        self.packed += 1;
        if self.used == ENTRIES_PER_PAGE {
            self.flush_page()?;
        }
        Ok(())
    }
    fn pad(&mut self) -> io::Result<()> {
        if self.used != 0 {
            self.packed += (ENTRIES_PER_PAGE - self.used) as u64;
            self.flush_page()?;
        }
        Ok(())
    }
    fn flush_page(&mut self) -> io::Result<()> {
        seal(&mut self.page);
        self.file.write_all(&self.page)?;
        self.page.fill(0);
        self.used = 0;
        Ok(())
    }
    fn slot(&mut self, slot: u32, start: u64, len: u64) -> io::Result<()> {
        let start = u32::try_from(start).map_err(|_| invalid("kin directory start overflow"))?;
        let len = u32::try_from(len).map_err(|_| invalid("kin directory length overflow"))?;
        let at = (slot as usize % SLOTS_PER_PAGE) * 8;
        self.directory
            .get_mut(at..at + 4)
            .ok_or_else(|| invalid("kin slot offset"))?
            .copy_from_slice(&start.to_le_bytes());
        self.directory
            .get_mut(at + 4..at + 8)
            .ok_or_else(|| invalid("kin slot length offset"))?
            .copy_from_slice(&len.to_le_bytes());
        if slot as usize % SLOTS_PER_PAGE == SLOTS_PER_PAGE - 1 {
            self.flush_directory()?;
        }
        Ok(())
    }
    fn flush_directory(&mut self) -> io::Result<()> {
        let resume = self.file.stream_position()?;
        self.file.seek(SeekFrom::Start((1 + self.directory_page) * PAGE_BYTES as u64))?;
        seal(&mut self.directory);
        self.file.write_all(&self.directory)?;
        self.file.seek(SeekFrom::Start(resume))?;
        self.directory.fill(0);
        self.directory_page += 1;
        Ok(())
    }
}

fn seal(page: &mut [u8; PAGE_BYTES]) {
    let crc = crc32fast::hash(&page[..PAGE_BYTES - 4]);
    page[PAGE_BYTES - 4..].copy_from_slice(&crc.to_le_bytes());
}

fn encode_header(binding: Binding, head: TableHeader) -> [u8; TABLE_HEADER_BYTES] {
    let mut bytes = [0; TABLE_HEADER_BYTES];
    bytes[..8].copy_from_slice(MAGIC);
    bytes[8..12].copy_from_slice(&VERSION.to_le_bytes());
    bytes[12..16].copy_from_slice(&binding.head_crc.to_le_bytes());
    bytes[16..24].copy_from_slice(&binding.seq.to_le_bytes());
    bytes[24..32].copy_from_slice(&binding.data_end.to_le_bytes());
    bytes[32..40].copy_from_slice(&binding.count.to_le_bytes());
    bytes[40..48].copy_from_slice(&head.entries.to_le_bytes());
    bytes[56..64].copy_from_slice(&head.packed_entries.to_le_bytes());
    bytes[48..52].copy_from_slice(&head.slots.to_le_bytes());
    bytes[52..56].copy_from_slice(&head.directory_pages.to_le_bytes());
    seal(&mut bytes);
    bytes
}

pub(super) fn decode_header(
    bytes: &[u8; TABLE_HEADER_BYTES],
    binding: Binding,
    length: u64,
) -> io::Result<TableHeader> {
    if &bytes[..8] != MAGIC
        || read_u32(&bytes[8..12])? != VERSION
        || read_u32(&bytes[PAGE_BYTES - 4..])? != crc32fast::hash(&bytes[..PAGE_BYTES - 4])
        || read_u32(&bytes[12..16])? != binding.head_crc
        || read_u64(&bytes[16..24])? != binding.seq
        || read_u64(&bytes[24..32])? != binding.data_end
        || read_u64(&bytes[32..40])? != binding.count
    {
        return Err(invalid("kin header binding or checksum"));
    }
    let head = TableHeader {
        entries: read_u64(&bytes[40..48])?,
        slots: read_u32(&bytes[48..52])?,
        directory_pages: read_u32(&bytes[52..56])?,
        packed_entries: read_u64(&bytes[56..64])?,
    };
    let expected_slots = head.entries.div_ceil(64).max(1).checked_next_power_of_two();
    let directory_pages =
        if head.entries == 0 { 0 } else { head.slots.div_ceil(SLOTS_PER_PAGE as u32) };
    if expected_slots != Some(u64::from(head.slots))
        || head.directory_pages != directory_pages
        || head.entries > head.packed_entries
        || head.packed_entries > u64::from(u32::MAX)
        || (head.entries == 0 && head.packed_entries != 0)
        || (1 + u64::from(directory_pages) + head.packed_entries.div_ceil(ENTRIES_PER_PAGE as u64))
            * PAGE_BYTES as u64
            != length
    {
        return Err(invalid("kin table extent"));
    }
    Ok(head)
}
