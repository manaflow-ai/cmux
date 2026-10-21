//! Bounded retention for harness-owned copies of Chief turn transcripts.
//!
//! OptChat memory is the durable record. Claude Code and Codex keep debugging
//! copies of a turn's whole prompt, so the host removes only the exact project
//! and session directories it owns after [`TURN_TRANSCRIPT_DAYS`]. It never
//! walks another project or the user's whole harness home.

use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use crate::paths::Paths;
use crate::session_dir::TURN_TRANSCRIPT_DAYS;

#[derive(Clone, Debug)]
pub struct TurnRetention {
    roots: Vec<PathBuf>,
    keep: Duration,
}

impl TurnRetention {
    pub fn new(paths: &Paths, user_claude_home: &Path) -> TurnRetention {
        let project = crate::compactor::project_dir_name(&paths.session);
        TurnRetention {
            roots: vec![
                paths.claude_config.join("projects").join(&project),
                user_claude_home.join("projects").join(project),
                paths.turn_codex.join("sessions"),
                paths.turn_codex.join("shell_snapshots"),
            ],
            keep: Duration::from_secs(TURN_TRANSCRIPT_DAYS * 24 * 60 * 60),
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
        Ok(removed)
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
        let retention = TurnRetention::new(&paths, user.path());
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
}
