//! Persist after each turn (section 10: "the reference commits the directory
//! with git"). The memory lives in SQLite; after every turn this thread
//! brings the plain-text export in the chat directory up to date (the JSONL
//! day files, `optchat_host::db::Exporter`, through a read-only connection)
//! and commits it: the chat directory is a git repository, as before the
//! move to SQLite, so its history goes on unchanged. One thread exports and
//! commits, in turn order, so the brain never waits on either. Then the
//! commits are pushed to the Chief's private backup repository
//! (`crate::backup`: secret scan first, retried with backoff, never forced).

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc::{RecvTimeoutError, Sender, channel};
use std::time::Instant;

use crate::backup::{Backup, Outcome};

use optchat_host::db::{Exporter, ReadOnly};

pub struct Persister {
    tx: Sender<String>,
}

impl Persister {
    /// Exports the database `db` into `dir`, commits `dir` and pushes it
    /// (`backup`, when given) after each `turn_ended`; a failed push is
    /// tried again when it is due. Failures are logged; a missing git is
    /// said once.
    pub fn start(
        dir: PathBuf,
        db: PathBuf,
        backup: Option<Backup>,
        log: crate::brain::Log,
    ) -> std::io::Result<Persister> {
        let (tx, rx) = channel::<String>();
        std::thread::Builder::new()
            .name("persist".into())
            .spawn(move || {
                let mut told = false;
                let mut export = Export::new(&dir, &db);
                let mut backup = backup;
                let mut last: Option<Outcome> = None;
                loop {
                    let due = backup.as_ref().and_then(Backup::due);
                    let key = match due {
                        Some(at) => {
                            match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                                Ok(key) => Some(key),
                                Err(RecvTimeoutError::Timeout) => None,
                                Err(RecvTimeoutError::Disconnected) => break,
                            }
                        }
                        None => match rx.recv() {
                            Ok(key) => Some(key),
                            Err(_) => break,
                        },
                    };
                    if let Some(key) = &key {
                        if let Err(e) = export.sync() {
                            log(&format!(
                                "exporting the memory after turn {key} failed: {e}"
                            ));
                        }
                        if let Err(e) = snapshot(&dir, key)
                            && !told
                        {
                            told = true;
                            log(&format!(
                                "committing the memory after turn {key} failed: {e} (said once)"
                            ));
                        }
                    }
                    if let Some(backup) = backup.as_mut() {
                        let outcome = backup.run(&dir);
                        if let Some(line) = describe(&outcome, last.as_ref()) {
                            log(&line);
                        }
                        last = Some(outcome);
                    }
                }
            })?;
        Ok(Persister { tx })
    }

    pub fn turn_ended(&self, key: &str) {
        let _ = self.tx.send(key.to_owned());
    }
}

/// The host.log line of a backup outcome: a hold or a failure each time it
/// changes, a push after a hold or a failure.
fn describe(outcome: &Outcome, last: Option<&Outcome>) -> Option<String> {
    match outcome {
        Outcome::Held { what, rule } if last != Some(outcome) => Some(format!(
            "backup held: possible secret in {what} ({rule}); allow it in backup-allow.txt to push"
        )),
        Outcome::Failed { error, retry } => Some(format!(
            "backup push failed (retrying in {} s): {error}",
            retry.as_secs()
        )),
        Outcome::Pushed { head } if !matches!(last, Some(Outcome::Pushed { .. }) | None) => {
            Some(format!("backup pushed {head} again"))
        }
        _ => None,
    }
}

/// The export's read-only connection, opened on first use, and its watermark.
struct Export {
    db: PathBuf,
    conn: Option<ReadOnly>,
    exporter: Exporter,
}

impl Export {
    fn new(dir: &Path, db: &Path) -> Export {
        Export {
            db: db.to_owned(),
            conn: None,
            exporter: Exporter::new(dir),
        }
    }

    fn sync(&mut self) -> std::io::Result<()> {
        if self.conn.is_none() {
            self.conn = Some(ReadOnly::open(&self.db)?);
        }
        match &self.conn {
            Some(conn) => self.exporter.sync(conn).map(|_| ()),
            None => Ok(()),
        }
    }
}

pub(crate) fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
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

/// What the memory's repository never tracks: process state, temporary
/// files, the export's watermark, and the database itself when it sits in
/// the chat directory (tests; the host keeps it one level up).
const IGNORED: [&str; 6] = [
    "lock",
    "*.tmp*",
    "takeover.flock",
    ".export.json",
    "memory.sqlite3*",
    "*.export.tmp",
];

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
