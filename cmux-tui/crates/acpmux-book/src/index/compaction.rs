//! Crash-safe snapshot installation after an O(1) log-generation rotation.
use super::{DiskSnapshot, RowKey, SortedSnapshot, Summary, SummaryIndex};
use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug)]
pub struct Compaction {
    directory: PathBuf,
    pub(super) snapshot_path: PathBuf,
    covered_generation: u64,
    seq: u64,
    captured_now: u64,
}

#[derive(Debug)]
pub struct CompactionResult {
    pub snapshot: Arc<DiskSnapshot>,
    /// Cold in-memory rows covered by this capture, removed in bounded turns.
    pub cold_keys: VecDeque<RowKey>,
    /// Hot disk rows that startup hydration had not reached at capture.
    pub missing_hot: VecDeque<Arc<Summary>>,
    pub covered_generation: u64,
    pub seq: u64,
    pub cleanup_errors: u64,
}

impl Compaction {
    pub(super) fn new(directory: PathBuf, covered_generation: u64, seq: u64) -> Self {
        let captured_now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |time| u64::try_from(time.as_millis()).unwrap_or(u64::MAX));
        Self {
            snapshot_path: directory.join("index.snap"),
            directory,
            covered_generation,
            seq,
            captured_now,
        }
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
        if cancelled.load(Ordering::Acquire) {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "compaction cancelled"));
        }
        // This worker is the directory's sole compactor. A prior attempt may
        // have failed to unlink its files while storage was unavailable. Retry
        // that cleanup before reserving a stage, without requiring a restart
        // or allocating another staging name. read_dir keeps memory bounded.
        cleanup_stages(&self.directory)?;
        let mut files = StageFiles::reserve(&self.snapshot_path, self.seq)?;
        let result = self.run_staged(index, &cancelled, files.stage());
        match (result, files.cleanup()) {
            (Ok(mut result), Err(_)) => {
                // A completed rename is still committed even if cleanup fails.
                result.cleanup_errors += 1;
                Ok(result)
            }
            (Err(error), Err(cleanup)) => Err(io::Error::new(
                error.kind(),
                format!("{error}; compaction stage cleanup failed: {cleanup}"),
            )),
            (result, Ok(())) => result,
        }
    }

    fn run_staged(
        self,
        index: Arc<SummaryIndex>,
        cancelled: &AtomicBool,
        stage: &Path,
    ) -> io::Result<CompactionResult> {
        // The write path streams rows and keeps only sparse checkpoint state.
        let mut cold_keys = VecDeque::new();
        let mut missing_hot = VecDeque::new();
        SortedSnapshot::write_stream_generation(
            stage,
            self.seq,
            0,
            None,
            self.covered_generation,
            index.merged_rows().map(|row| {
                if cancelled.load(Ordering::Acquire) {
                    return Err(io::Error::new(io::ErrorKind::Interrupted, "compaction cancelled"));
                }
                let row = row?;
                let held = index.get_row(&row.key()).is_some();
                if row.is_hot_at(self.captured_now) {
                    if !held {
                        missing_hot.push_back(row.clone());
                    }
                } else if held {
                    cold_keys.push_back(row.key());
                }
                Ok(row)
            }),
        )?;
        if cancelled.load(Ordering::Acquire) {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "compaction cancelled"));
        }
        // Open the staged inode before committing it. Errors after rename
        // must not leave the publisher believing the old generation is current.
        let snapshot = DiskSnapshot::open(stage)?
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "staged snapshot"))?;
        fs::rename(stage, &self.snapshot_path)?;
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
            cold_keys,
            missing_hot,
            covered_generation: self.covered_generation,
            seq: self.seq,
            cleanup_errors,
        })
    }
}

struct StageFiles {
    paths: [PathBuf; 3],
    armed: bool,
}

impl StageFiles {
    fn reserve(snapshot: &Path, seq: u64) -> io::Result<Self> {
        let stage = snapshot.with_file_name(format!("index.snap.stage.{seq}"));
        let sidefile = |suffix: &str| {
            let mut name = stage.as_os_str().to_os_string();
            name.push(suffix);
            PathBuf::from(name)
        };
        let paths = [stage.clone(), sidefile(".new"), sidefile(".directory.new")];
        // There is one compactor per directory. Known abandoned files were
        // removed before reservation; do not overwrite unexpected entries.
        for path in &paths {
            match fs::symlink_metadata(path) {
                Ok(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        "compaction stage already exists",
                    ));
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
        OpenOptions::new().create_new(true).write(true).open(stage)?;
        Ok(Self { paths, armed: true })
    }

    fn stage(&self) -> &Path {
        let [stage, ..] = &self.paths;
        stage
    }

    fn cleanup(&mut self) -> io::Result<()> {
        let mut failed = None;
        for path in &self.paths {
            if let Err(error) = fs::remove_file(path)
                && error.kind() != io::ErrorKind::NotFound
                && failed.is_none()
            {
                failed = Some(error);
            }
        }
        if let Some(error) = failed {
            return Err(error);
        }
        self.armed = false;
        Ok(())
    }
}

impl Drop for StageFiles {
    fn drop(&mut self) {
        if self.armed {
            let _ = self.cleanup();
        }
    }
}

/// Only the compactor's numeric staging names are owned by this directory.
/// Older attempts also used a `.stage` suffix after the sequence component.
pub(super) fn cleanup_stages(directory: &Path) -> io::Result<bool> {
    let mut cleaned = false;
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(suffix) = name.strip_prefix("index.snap.stage.") else { continue };
        let (number, suffix) = suffix.split_once('.').unwrap_or((suffix, ""));
        if number.parse::<u64>().is_ok()
            && matches!(
                suffix,
                "" | "new" | "directory.new" | "stage" | "stage.new" | "stage.directory.new"
            )
            && entry.file_type()?.is_file()
        {
            fs::remove_file(entry.path())?;
            cleaned = true;
        }
    }
    Ok(cleaned)
}

fn generation_number(path: &Path) -> Option<u64> {
    let name = path.file_name()?.to_str()?;
    let suffix = name.strip_prefix("index.log.")?;
    suffix.parse().ok()
}
