//! Where `_acpmux/complete` runs: one fixed, empty, private cwd for every
//! recipe (`<acpmux home>/complete/cwd`, never written to), so Claude Code
//! records one project entry in `~/.claude.json`, not one per run, and no
//! project `CLAUDE.md` or `AGENTS.md` loads; and a per-run private folder
//! under `<acpmux home>/complete/runs` for the prompt and output files only,
//! removed after the run and swept at daemon start when a crash left one.

use std::path::{Path, PathBuf};
use std::time::Duration;

/// The name every run folder starts with (`run::RunDir`).
pub const RUN_PREFIX: &str = "acpmux-complete-";

/// A run folder older than this at daemon start is a crashed run's: no
/// completion runs longer than `MAX_TIMEOUT_MS`.
pub const STALE_RUN: Duration = Duration::from_secs(10 * 60);

/// The one-shot's folders under `root`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Places {
    root: PathBuf,
}

impl Places {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// The daemon's own: under this acpmux home.
    pub fn for_daemon() -> Self {
        Self::new(Self::root_in(&crate::config::home(), dirs::home_dir().as_deref()))
    }

    /// `<acpmux home>/complete`, or a folder in the per-user temp dir when
    /// the acpmux home is a guarded folder (`protected_folders`).
    pub fn root_in(acpmux_home: &Path, home: Option<&Path>) -> PathBuf {
        let own = acpmux_home.join("complete");
        if crate::protected_folders::refusal_in(&own, home).is_none() {
            own
        } else {
            std::env::temp_dir().join("acpmux-oneshot")
        }
    }

    /// The fixed cwd of every run.
    pub fn cwd(&self) -> PathBuf {
        self.root.join("cwd")
    }

    /// Where each run's own folder goes.
    pub fn runs(&self) -> PathBuf {
        self.root.join("runs")
    }

    /// Creates the folders, owner-only.
    pub fn ensure(&self) -> anyhow::Result<()> {
        for dir in [self.root.clone(), self.cwd(), self.runs()] {
            crate::agent_host::ensure_private_dir(&dir)?;
        }
        Ok(())
    }

    /// Removes run folders (`acpmux-complete-*`) last changed at least
    /// `older_than` ago; returns how many.
    pub fn sweep_stale_runs(&self, older_than: Duration) -> usize {
        let Ok(entries) = std::fs::read_dir(self.runs()) else { return 0 };
        let mut swept = 0;
        for entry in entries.flatten() {
            let run = entry.file_name().to_string_lossy().starts_with(RUN_PREFIX);
            let old = entry
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.elapsed().ok())
                .is_some_and(|age| age >= older_than);
            if run && old && std::fs::remove_dir_all(entry.path()).is_ok() {
                swept += 1;
            }
        }
        swept
    }
}
