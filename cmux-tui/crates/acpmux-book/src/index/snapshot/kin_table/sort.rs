//! Fixed-record external sort with bounded memory, fan-in, and run bookkeeping.

use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::marker::PhantomData;
use std::mem::size_of;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const TOTAL_BYTES: usize = 4 * 1024 * 1024;
// Ingestion owns three sorters. Reserve the fourth quarter for merge readers,
// writers, heap heads and fixed metadata; their space never grows with rows.
const RUN_BYTES: usize = TOTAL_BYTES / 4;
const FAN_IN: u64 = 32;
const IO_BYTES: usize = 16 * 1024;
// This deliberately counts all three buffers even though a merging sorter
// releases its own buffer first. The remaining allowance covers fixed heads,
// paths and record scratch space for the three record types used by Builder.
const _: () = assert!(3 * RUN_BYTES + (FAN_IN as usize + 4) * IO_BYTES + 64 * 1024 <= TOTAL_BYTES);
static TEMP_ID: AtomicU64 = AtomicU64::new(0);

pub(super) trait Record: Copy + Ord {
    const WIDTH: usize;
    fn encode(self, bytes: &mut [u8]) -> io::Result<()>;
    fn decode(bytes: &[u8]) -> io::Result<Self>;
}

struct TempSpace {
    path: PathBuf,
    next: AtomicU64,
}

impl TempSpace {
    fn new(parent: &Path) -> io::Result<Arc<Self>> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
        for _ in 0..128 {
            let id = TEMP_ID.fetch_add(1, Ordering::Relaxed);
            let path = parent.join(format!("acpmux-kin-{}-{stamp}-{id}", std::process::id()));
            let mut directory = fs::DirBuilder::new();
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                directory.mode(0o700);
            }
            match directory.create(&path) {
                Ok(()) => return Ok(Arc::new(Self { path, next: AtomicU64::new(0) })),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(io::ErrorKind::AlreadyExists, "kin temporary directory collision"))
    }

    fn path(&self, id: u64) -> PathBuf {
        self.path.join(id.to_string())
    }

    fn create(&self) -> io::Result<(u64, BufWriter<File>)> {
        // Creation is serial within a sorter. Register only a successful
        // create_new, so cleanup never claims a name whose creation failed.
        let id = self.next.load(Ordering::Relaxed);
        let file = OpenOptions::new().create_new(true).write(true).open(self.path(id))?;
        self.next.store(id + 1, Ordering::Relaxed);
        Ok((id, BufWriter::with_capacity(IO_BYTES, file)))
    }
}

impl Drop for TempSpace {
    fn drop(&mut self) {
        // Every numeric filename was exclusively created by this owner. Keep
        // only the counter, rather than a path allocation for every spill run.
        for id in 0..self.next.load(Ordering::Relaxed) {
            let _ = fs::remove_file(self.path(id));
        }
        let _ = fs::remove_dir(&self.path);
    }
}

pub(super) struct Sorter<R: Record> {
    space: Arc<TempSpace>,
    memory: Vec<R>,
    limit: usize,
    runs: u64,
    count: u64,
}

impl<R: Record> Sorter<R> {
    pub(super) fn in_directory(directory: &Path) -> io::Result<Self> {
        Self::with_budget_in(directory, RUN_BYTES)
    }

    #[cfg(test)]
    fn with_budget(bytes: usize) -> io::Result<Self> {
        Self::with_budget_in(&std::env::temp_dir(), bytes)
    }

    fn with_budget_in(directory: &Path, bytes: usize) -> io::Result<Self> {
        let limit = (bytes / size_of::<R>().max(R::WIDTH).max(1)).max(1);
        Ok(Self {
            space: TempSpace::new(directory)?,
            memory: Vec::with_capacity(limit),
            limit,
            runs: 0,
            count: 0,
        })
    }

    pub(super) fn push(&mut self, record: R) -> io::Result<()> {
        self.memory.push(record);
        self.count =
            self.count.checked_add(1).ok_or_else(|| io::Error::other("kin record count"))?;
        if self.memory.len() == self.limit {
            self.flush()?;
        }
        Ok(())
    }

    fn flush(&mut self) -> io::Result<()> {
        if self.memory.is_empty() {
            return Ok(());
        }
        self.memory.sort_unstable();
        let (id, mut output) = self.space.create()?;
        debug_assert_eq!(id, self.runs);
        let mut bytes = vec![0; R::WIDTH];
        for record in self.memory.drain(..) {
            record.encode(&mut bytes)?;
            output.write_all(&bytes)?;
        }
        output.flush()?;
        self.runs += 1;
        Ok(())
    }

    pub(super) fn finish(mut self) -> io::Result<SortedFile<R>> {
        self.flush()?;
        // Release the run buffer before allocating the bounded merge inputs.
        drop(self.memory);
        let mut first = 0;
        let mut count = self.runs;
        if count == 0 {
            let (id, mut output) = self.space.create()?;
            output.flush()?;
            return SortedFile::open(self.space, id, 0);
        }
        while count > 1 {
            let output_first = self.space.next.load(Ordering::Relaxed);
            let mut consumed = 0;
            while consumed < count {
                let batch = (count - consumed).min(FAN_IN);
                merge::<R>(&self.space, first + consumed, batch)?;
                consumed += batch;
            }
            first = output_first;
            count = count.div_ceil(FAN_IN);
        }
        SortedFile::open(self.space, first, self.count)
    }

    /// Keep the first of each contiguous equivalence class in sorted order.
    /// The returned count describes the rewritten disk stream, not its input.
    pub(super) fn finish_unique_by(
        self,
        same: impl FnMut(&R, &R) -> bool,
    ) -> io::Result<SortedFile<R>> {
        self.finish()?.unique_by(same)
    }
}

fn merge<R: Record>(space: &TempSpace, first: u64, count: u64) -> io::Result<()> {
    let mut inputs = Vec::with_capacity(count as usize);
    let mut heap = BinaryHeap::with_capacity(count as usize);
    let mut bytes = vec![0; R::WIDTH];
    for id in first..first + count {
        let mut input = BufReader::with_capacity(IO_BYTES, File::open(space.path(id))?);
        if let Some(record) = read_record::<R>(&mut input, &mut bytes)? {
            heap.push(Reverse((record, inputs.len())));
        }
        inputs.push(input);
    }
    let (_, mut output) = space.create()?;
    while let Some(Reverse((record, index))) = heap.pop() {
        record.encode(&mut bytes)?;
        output.write_all(&bytes)?;
        if let Some(next) = read_record::<R>(
            inputs.get_mut(index).ok_or_else(|| io::Error::other("kin merge input index"))?,
            &mut bytes,
        )? {
            heap.push(Reverse((next, index)));
        }
    }
    output.flush()?;
    drop(output);
    drop(inputs);
    for id in first..first + count {
        fs::remove_file(space.path(id))?;
    }
    Ok(())
}

fn read_record<R: Record>(input: &mut impl Read, bytes: &mut [u8]) -> io::Result<Option<R>> {
    // Distinguish a clean boundary from a truncated final record.
    let (first, rest) =
        bytes.split_first_mut().ok_or_else(|| io::Error::other("empty kin record"))?;
    let read = loop {
        match input.read(std::slice::from_mut(first)) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => break result?,
        }
    };
    if read == 0 {
        return Ok(None);
    }
    input.read_exact(rest)?;
    R::decode(bytes).map(Some)
}

pub(super) struct SortedFile<R: Record> {
    // Close the reader before its owning directory is removed (Windows too).
    input: BufReader<File>,
    _space: Arc<TempSpace>,
    bytes: Vec<u8>,
    pub(super) count: u64,
    _record: PhantomData<R>,
}

impl<R: Record> SortedFile<R> {
    fn open(space: Arc<TempSpace>, id: u64, count: u64) -> io::Result<Self> {
        let input = BufReader::with_capacity(IO_BYTES, File::open(space.path(id))?);
        Ok(Self { input, _space: space, bytes: vec![0; R::WIDTH], count, _record: PhantomData })
    }

    pub(super) fn next(&mut self) -> io::Result<Option<R>> {
        read_record::<R>(&mut self.input, &mut self.bytes)
    }

    pub(super) fn rewind(&mut self) -> io::Result<()> {
        self.input.seek(SeekFrom::Start(0))?;
        Ok(())
    }

    fn unique_by(mut self, mut same: impl FnMut(&R, &R) -> bool) -> io::Result<Self> {
        let (id, mut output) = self._space.create()?;
        let mut previous = None;
        let mut count = 0u64;
        while let Some(record) = self.next()? {
            if previous.as_ref().is_some_and(|previous| same(previous, &record)) {
                continue;
            }
            record.encode(&mut self.bytes)?;
            output.write_all(&self.bytes)?;
            count =
                count.checked_add(1).ok_or_else(|| io::Error::other("kin unique record count"))?;
            previous = Some(record);
        }
        output.flush()?;
        drop(output);
        Self::open(Arc::clone(&self._space), id, count)
    }
}

#[cfg(test)]
#[path = "sort_tests.rs"]
mod tests;
