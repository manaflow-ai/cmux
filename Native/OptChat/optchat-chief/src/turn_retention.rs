//! Bounded retention for harness-owned copies of Chief turn transcripts.
//!
//! OptChat memory is the durable record. Claude Code and Codex keep debugging
//! copies of a turn's whole prompt, so the host removes only the exact project
//! and session directories it owns after [`TURN_TRANSCRIPT_DAYS`], and the
//! compactor's slot projects that a crash left after
//! [`crate::compactor::TRANSCRIPT_DAYS`]. It never walks another project or
//! the user's whole harness home. Chief sessions never set Claude Code's own
//! `cleanupPeriodDays` in project settings: that sweep reaches every project
//! of the store (session_dir::PROJECT_SETTINGS_STORE_WIDE_KEYS).

use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use crate::paths::Paths;
use crate::session_dir::TURN_TRANSCRIPT_DAYS;

#[derive(Clone, Debug)]
pub struct TurnRetention {
    roots: Vec<PathBuf>,
    keep: Duration,
    /// The Claude stores the compactor's slot sessions write to.
    compactor_stores: Vec<PathBuf>,
    /// The compactor's working directory (its `slot-<k>` directories).
    compactor_work: PathBuf,
    compactor_keep: Duration,
}

impl TurnRetention {
    pub fn new(paths: &Paths, user_claude_home: &Path, compactor_work: &Path) -> TurnRetention {
        let project = crate::compactor::project_dir_name(&paths.session);
        TurnRetention {
            roots: vec![
                paths.claude_config.join("projects").join(&project),
                user_claude_home.join("projects").join(project),
                paths.turn_codex.join("sessions"),
                paths.turn_codex.join("shell_snapshots"),
            ],
            keep: Duration::from_secs(TURN_TRANSCRIPT_DAYS * 24 * 60 * 60),
            compactor_stores: vec![
                paths.compactor_config.clone(),
                user_claude_home.to_path_buf(),
            ],
            compactor_work: compactor_work.to_path_buf(),
            compactor_keep: Duration::from_secs(crate::compactor::TRANSCRIPT_DAYS * 24 * 60 * 60),
        }
    }

    /// Removes expired files and now-empty subdirectories. Missing roots are
    /// normal (the corresponding harness has not run).
    pub fn cleanup(&self) -> io::Result<usize> {
        self.cleanup_at(SystemTime::now())
    }

    fn cleanup_at(&self, now: SystemTime) -> io::Result<usize> {
        let cutoff = now.checked_sub(self.keep).unwrap_or(SystemTime::UNIX_EPOCH);
        let mut removed = 0;
        for root in &self.roots {
            removed += prune(root, cutoff)?;
        }
        let cutoff = now
            .checked_sub(self.compactor_keep)
            .unwrap_or(SystemTime::UNIX_EPOCH);
        for root in self.compactor_projects()? {
            removed += prune(&root, cutoff)?;
            remove_if_empty(&root)?;
        }
        Ok(removed)
    }

    /// The compactor slot projects present in its stores: the project
    /// directories Claude Code names after `<work>/slot-<k>` (by the real
    /// path, and by the path as given in case it is not created yet).
    fn compactor_projects(&self) -> io::Result<Vec<PathBuf>> {
        let mut prefixes = vec![format!(
            "{}-slot-",
            crate::compactor::project_dir_name(&self.compactor_work)
        )];
        if let Ok(real) = std::fs::canonicalize(&self.compactor_work) {
            let real = format!("{}-slot-", crate::compactor::project_dir_name(&real));
            if !prefixes.contains(&real) {
                prefixes.push(real);
            }
        }
        let mut found = Vec::new();
        for store in &self.compactor_stores {
            let projects = store.join("projects");
            let entries = match std::fs::read_dir(&projects) {
                Ok(entries) => entries,
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e),
            };
            for entry in entries {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().into_owned();
                let slot = prefixes.iter().any(|prefix| {
                    name.strip_prefix(prefix.as_str())
                        .is_some_and(|k| !k.is_empty() && k.bytes().all(|b| b.is_ascii_digit()))
                });
                if slot && entry.file_type()?.is_dir() {
                    found.push(entry.path());
                }
            }
        }
        Ok(found)
    }
}

fn remove_if_empty(dir: &Path) -> io::Result<()> {
    match std::fs::remove_dir(dir) {
        Ok(()) => Ok(()),
        Err(e)
            if matches!(
                e.kind(),
                io::ErrorKind::DirectoryNotEmpty | io::ErrorKind::NotFound
            ) =>
        {
            Ok(())
        }
        Err(e) => Err(e),
    }
}

fn prune(path: &Path, cutoff: SystemTime) -> io::Result<usize> {
    let entries = match std::fs::read_dir(path) {
        Ok(entries) => entries,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(0),
        Err(e) => return Err(e),
    };
    let mut removed = 0;
    for entry in entries {
        let entry = entry?;
        let child = entry.path();
        let kind = entry.file_type()?;
        if kind.is_dir() {
            removed += prune(&child, cutoff)?;
            match std::fs::remove_dir(&child) {
                Ok(()) => {}
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::DirectoryNotEmpty | io::ErrorKind::NotFound
                    ) => {}
                Err(e) => return Err(e),
            }
            continue;
        }
        let modified = entry
            .metadata()?
            .modified()
            .unwrap_or(SystemTime::UNIX_EPOCH);
        if modified <= cutoff {
            std::fs::remove_file(&child)?;
            removed += 1;
        }
    }
    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_chiefs_exact_harness_copies_expire() {
        let root = tempfile::tempdir().unwrap();
        let user = tempfile::tempdir().unwrap();
        let paths = Paths::new(root.path());
        let retention = TurnRetention::new(&paths, user.path(), &root.path().join("work"));
        for dir in &retention.roots {
            std::fs::create_dir_all(dir.join("day")).unwrap();
            std::fs::write(dir.join("day/turn.jsonl"), "private turn").unwrap();
        }
        let other = user.path().join("projects/another-project/keep.jsonl");
        std::fs::create_dir_all(other.parent().unwrap()).unwrap();
        std::fs::write(&other, "other project").unwrap();

        assert_eq!(retention.cleanup_at(SystemTime::now()).unwrap(), 0);
        assert_eq!(
            retention
                .cleanup_at(SystemTime::now() + Duration::from_secs(3 * 24 * 60 * 60))
                .unwrap(),
            retention.roots.len()
        );
        assert!(
            retention
                .roots
                .iter()
                .all(|dir| !dir.join("day/turn.jsonl").exists())
        );
        assert!(
            other.exists(),
            "another project is outside this Chief's retention scope"
        );
    }

    /// A compactor transcript a crash left (`end` never ran) expires after
    /// the compactor's day in either store; the user's other projects,
    /// including ones whose names start like a slot's, stay.
    #[test]
    fn a_crashed_compactor_transcript_expires_and_nothing_else_does() {
        let root = tempfile::tempdir().unwrap();
        let user = tempfile::tempdir().unwrap();
        let paths = Paths::new(root.path());
        let work = root.path().join("tmp/optchat-compact-abc");
        std::fs::create_dir_all(work.join("slot-0")).unwrap();
        let retention = TurnRetention::new(&paths, user.path(), &work);
        let real = std::fs::canonicalize(&work).unwrap();
        let slot = |store: &Path, k: &str| {
            store.join("projects").join(format!(
                "{}-slot-{k}",
                crate::compactor::project_dir_name(&real)
            ))
        };
        let crashed = [
            slot(user.path(), "0").join("node.jsonl"),
            slot(&paths.compactor_config, "3").join("node.jsonl"),
        ];
        let kept = [
            user.path().join("projects/another-project/chat.jsonl"),
            slot(user.path(), "x").join("not-a-slot.jsonl"),
            user.path().join(format!(
                "projects/{}-slot-0-other/chat.jsonl",
                crate::compactor::project_dir_name(&real)
            )),
        ];
        for file in crashed.iter().chain(&kept) {
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, "{}").unwrap();
        }

        assert_eq!(retention.cleanup_at(SystemTime::now()).unwrap(), 0);
        let later = SystemTime::now() + Duration::from_secs(36 * 60 * 60);
        assert_eq!(retention.cleanup_at(later).unwrap(), crashed.len());
        for file in &crashed {
            assert!(!file.exists(), "{}", file.display());
            assert!(
                !file.parent().unwrap().exists(),
                "the empty slot project goes"
            );
        }
        for file in &kept {
            assert!(file.exists(), "{} is not a compactor slot", file.display());
        }
    }
}
