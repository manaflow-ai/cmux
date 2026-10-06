//! Persist after each turn (section 10: "the reference commits the directory
//! with git"): the chat directory is a git repository, and every turn ends
//! with a commit of its log and tree. One thread commits, in turn order, so
//! the brain never waits on git. The commits are local; pushing them
//! elsewhere (the backup) is the user's choice of remote.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc::{Sender, channel};

pub struct Persister {
    tx: Sender<String>,
}

impl Persister {
    /// Commits `dir` after each `turn_ended`. Failures are logged; a missing
    /// git is said once.
    pub fn start(dir: PathBuf, log: crate::brain::Log) -> std::io::Result<Persister> {
        let (tx, rx) = channel::<String>();
        std::thread::Builder::new()
            .name("persist".into())
            .spawn(move || {
                let mut told = false;
                for key in rx {
                    if let Err(e) = snapshot(&dir, &key)
                        && !told
                    {
                        told = true;
                        log(&format!(
                            "committing the memory after turn {key} failed: {e} (said once)"
                        ));
                    }
                }
            })?;
        Ok(Persister { tx })
    }

    pub fn turn_ended(&self, key: &str) {
        let _ = self.tx.send(key.to_owned());
    }
}

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=optchat-chief",
            "-c",
            "user.email=optchat-chief@localhost",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .output()
        .map_err(|e| format!("running git: {e}"))?;
    let text =
        String::from_utf8_lossy(&out.stdout).into_owned() + &String::from_utf8_lossy(&out.stderr);
    if out.status.success() {
        Ok(text)
    } else {
        Err(format!("git {}: {}", args.join(" "), text.trim()))
    }
}

/// What the memory's repository never tracks.
const IGNORED: [&str; 3] = ["lock", "*.tmp*", "takeover.flock"];

/// Commits everything in `dir` (creating the repository on first use) with
/// the turn key as the message. A turn that changed nothing commits nothing.
pub fn snapshot(dir: &Path, key: &str) -> Result<(), String> {
    if !dir.join(".git").exists() {
        git(dir, &["init", "-q"])?;
    }
    // The chat's single-writer lock and its takeover flock are process
    // state, not history; a repository made before takeover.flock was
    // listed stops tracking it.
    let ignore = dir.join(".gitignore");
    let old = std::fs::read_to_string(&ignore).unwrap_or_default();
    let missing: Vec<&str> = IGNORED
        .iter()
        .copied()
        .filter(|p| !old.lines().any(|l| l == *p))
        .collect();
    if !missing.is_empty() {
        let mut text = old.clone();
        if !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        for p in &missing {
            text.push_str(p);
            text.push('\n');
        }
        std::fs::write(&ignore, text).map_err(|e| e.to_string())?;
        git(
            dir,
            &["rm", "-q", "--cached", "--ignore-unmatch", "takeover.flock"],
        )?;
    }
    git(dir, &["add", "-A"])?;
    if git(dir, &["diff", "--cached", "--quiet"]).is_ok() {
        return Ok(());
    }
    git(dir, &["commit", "-q", "-m", key]).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Audit round 3, m7: the takeover flock is process state too.
    #[test]
    fn lock_files_stay_out_of_the_history() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("lock"), "1").unwrap();
        std::fs::write(dir.path().join("takeover.flock"), "").unwrap();
        std::fs::write(dir.path().join("a.jsonl"), "{}\n").unwrap();
        snapshot(dir.path(), "turn:optchat:0:1").unwrap();
        let tracked = git(dir.path(), &["ls-files"]).unwrap();
        assert!(!tracked.contains("takeover.flock"), "{tracked}");
        assert!(!tracked.lines().any(|l| l == "lock"), "{tracked}");
    }

    // A repository made before the fix tracks takeover.flock: it is dropped.
    #[test]
    fn an_older_repository_stops_tracking_the_takeover_flock() {
        let dir = tempfile::tempdir().unwrap();
        git(dir.path(), &["init", "-q"]).unwrap();
        std::fs::write(dir.path().join(".gitignore"), "lock\n*.tmp*\n").unwrap();
        std::fs::write(dir.path().join("takeover.flock"), "").unwrap();
        git(dir.path(), &["add", "-A"]).unwrap();
        git(
            dir.path(),
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "commit",
                "-q",
                "-m",
                "old",
            ],
        )
        .unwrap();
        std::fs::write(dir.path().join("a.jsonl"), "{}\n").unwrap();
        snapshot(dir.path(), "turn:optchat:1:2").unwrap();
        let tracked = git(dir.path(), &["ls-files"]).unwrap();
        assert!(!tracked.contains("takeover.flock"), "{tracked}");
    }

    #[test]
    fn each_turn_with_changes_is_one_commit() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("lock"), "1").unwrap();
        std::fs::create_dir(dir.path().join("main")).unwrap();
        std::fs::write(dir.path().join("main/a.jsonl"), "{}\n").unwrap();
        snapshot(dir.path(), "turn:optchat:0:1").unwrap();
        snapshot(dir.path(), "turn:optchat:0:1").unwrap();
        std::fs::write(dir.path().join("main/a.jsonl"), "{}\n{}\n").unwrap();
        snapshot(dir.path(), "turn:optchat:2:3").unwrap();
        let log = git(dir.path(), &["log", "--format=%s"]).unwrap();
        assert_eq!(log, "turn:optchat:2:3\nturn:optchat:0:1\n");
        let tracked = git(dir.path(), &["ls-files"]).unwrap();
        assert!(!tracked.lines().any(|l| l == "lock"), "{tracked}");
    }
}
