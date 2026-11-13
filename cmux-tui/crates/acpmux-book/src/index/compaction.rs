//! Crash-safe snapshot installation after an O(1) log-generation rotation.
use super::{DiskSnapshot, SortedSnapshot, SummaryIndex};
use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

#[derive(Debug)]
pub struct Compaction {
    directory: PathBuf,
    pub(super) snapshot_path: PathBuf,
    covered_generation: u64,
    seq: u64,
}

#[derive(Debug)]
pub struct CompactionResult {
    pub snapshot: Arc<DiskSnapshot>,
    pub covered_generation: u64,
    pub seq: u64,
    pub cleanup_errors: u64,
}

impl Compaction {
    pub(super) fn new(directory: PathBuf, covered_generation: u64, seq: u64) -> Self {
        Self { snapshot_path: directory.join("index.snap"), directory, covered_generation, seq }
    }

    pub fn covered_generation(&self) -> u64 {
        self.covered_generation
    }
    pub fn seq(&self) -> u64 {
        self.seq
    }

    pub fn run(self, index: Arc<SummaryIndex>) -> io::Result<CompactionResult> {
        self.run_cancellable(index, Arc::new(AtomicBool::new(false)))
    }

    pub fn run_cancellable(
        self,
        index: Arc<SummaryIndex>,
        cancelled: Arc<AtomicBool>,
    ) -> io::Result<CompactionResult> {
        let stage = unique_stage(&self.snapshot_path, self.seq)?;
        if cancelled.load(Ordering::Acquire) {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "compaction cancelled"));
        }
        // The write path streams rows and keeps only sparse checkpoint state.
        SortedSnapshot::write_stream_generation(
            &stage,
            self.seq,
            0,
            None,
            self.covered_generation,
            index.merged_rows().map(|row| {
                if cancelled.load(Ordering::Acquire) {
                    Err(io::Error::new(io::ErrorKind::Interrupted, "compaction cancelled"))
                } else {
                    row
                }
            }),
        )?;
        if cancelled.load(Ordering::Acquire) {
            let _ = fs::remove_file(&stage);
            return Err(io::Error::new(io::ErrorKind::Interrupted, "compaction cancelled"));
        }
        // Open the staged inode before committing it. Errors after rename
        // must not leave the publisher believing the old generation is current.
        let snapshot = DiskSnapshot::open(&stage)?
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "staged snapshot"))?;
        fs::rename(&stage, &self.snapshot_path)?;
        let mut cleanup_errors = 0;
        if File::open(&self.directory).and_then(|directory| directory.sync_all()).is_err() {
            // Keep every old log until the rename is known durable.
            cleanup_errors += 1;
        } else {
            match fs::read_dir(&self.directory) {
                Ok(entries) => {
                    for entry in entries {
                        match entry {
                            Ok(entry) => {
                                let path = entry.path();
                                if generation_number(&path)
                                    .is_some_and(|generation| generation <= self.covered_generation)
                                    && fs::remove_file(path).is_err()
                                {
                                    cleanup_errors += 1;
                                }
                            }
                            Err(_) => cleanup_errors += 1,
                        }
                    }
                }
                Err(_) => cleanup_errors += 1,
            }
            if File::open(&self.directory).and_then(|directory| directory.sync_all()).is_err() {
                cleanup_errors += 1;
            }
        }
        Ok(CompactionResult {
            snapshot,
            covered_generation: self.covered_generation,
            seq: self.seq,
            cleanup_errors,
        })
    }
}

fn unique_stage(snapshot: &Path, seq: u64) -> io::Result<PathBuf> {
    let base = snapshot.with_file_name(format!("index.snap.stage.{seq}"));
    for n in 0..10_000u32 {
        let path = if n == 0 { base.clone() } else { base.with_extension(format!("{n}.stage")) };
        if !path.exists() {
            return Ok(path);
        }
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "snapshot staging names exhausted"))
}

fn generation_number(path: &Path) -> Option<u64> {
    let name = path.file_name()?.to_str()?;
    let suffix = name.strip_prefix("index.log.")?;
    suffix.parse().ok()
}
