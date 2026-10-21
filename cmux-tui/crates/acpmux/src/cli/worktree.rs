//! `acpmux worktree list|clean|restore|archives`: the machine's worktrees,
//! cleaned up after the agents that made them (`cmux-worktree-care`).
//!
//! - `list`: every linked worktree of the repositories under the roots and
//!   what a cleanup would do with it, and why.
//! - `clean`: does it. A worktree whose work lives only there is archived
//!   into git first (`refs/cmux/archive/<id>` and a bundle); a pushed one
//!   just goes; one still in use is never touched. `--dry-run` is `list`.
//! - `restore`: puts a reclaimed worktree back, by its folder, branch or
//!   archive id.
//! - `archives`: the manifests of reclaimed worktrees.
//!
//! The sessions come from every acpmux state folder on this machine (the
//! person's daemon, Chief's, a tagged build's), read from their session
//! files, so a session of a daemon this command does not talk to still keeps
//! its worktree. A session not closed keeps its worktree while its daemon
//! runs; a stopped daemon's sessions count as use at their last change.
//! A process working in a worktree keeps it too.

use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow};
use clap::{Subcommand, ValueEnum};
use cmux_worktree_care::Store;
use cmux_worktree_care::pass::{self, Options, Report};
use cmux_worktree_care::policy::{Action, Pressure, Session, Settings};
use cmux_worktree_care::restore::restore;
use serde::Deserialize;
use serde_json::json;

use crate::cli::output::print_json;

#[derive(Subcommand, Debug, PartialEq, Eq)]
pub enum WorktreeCmd {
    /// Every linked worktree and what a cleanup would do with it.
    #[command(alias = "ls")]
    List(Scope),
    /// Archive and remove idle worktrees, trim build output of kept ones.
    Clean {
        #[command(flatten)]
        scope: Scope,
        /// Only report, as `list` does.
        #[arg(long)]
        dry_run: bool,
    },
    /// Put a reclaimed worktree back: by its folder, branch or archive id.
    Restore {
        key: String,
        /// Somewhere else than its old folder.
        #[arg(long)]
        path: Option<PathBuf>,
    },
    /// Reclaimed worktrees, newest first.
    Archives {
        /// Also those already restored.
        #[arg(long)]
        all: bool,
    },
}

#[derive(clap::Args, Debug, PartialEq, Eq)]
pub struct Scope {
    /// Folders whose repositories are read (the folder and its children).
    /// Default: ~/Projects, ~/wt and its children, ~/.cmux/worktrees/*,
    /// ~/src, ~/code, plus every session's folder.
    #[arg(long = "root")]
    roots: Vec<PathBuf>,
    /// Decide as if the disk were this full.
    #[arg(long, value_enum)]
    pressure: Option<PressureArg>,
    /// Only this worktree (repeatable).
    #[arg(long = "only")]
    only: Vec<PathBuf>,
    /// Show the kept worktrees too.
    #[arg(long, short)]
    all: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
pub enum PressureArg {
    Normal,
    High,
    Critical,
}

pub fn run(cmd: WorktreeCmd, json_out: bool) -> Result<()> {
    let store = Store::open(Store::default_dir().ok_or_else(|| anyhow!("no home folder"))?)
        .map_err(|e| anyhow!(e))?;
    match cmd {
        WorktreeCmd::List(scope) => sweep(&scope, false, &store, json_out),
        WorktreeCmd::Clean { scope, dry_run } => sweep(&scope, !dry_run, &store, json_out),
        WorktreeCmd::Restore { key, path } => {
            let manifest =
                store.find(&key).ok_or_else(|| anyhow!("no reclaimed worktree matches {key}"))?;
            let restored = restore(&store, &manifest, path.as_deref()).map_err(|e| anyhow!(e))?;
            if json_out {
                print_json(&json!(restored));
                return Ok(());
            }
            let on = restored.branch.as_deref().unwrap_or("a detached HEAD");
            let with = if restored.archive { ", with its archived work" } else { "" };
            println!("restored {} on {on}{with}", restored.path.display());
            for note in &restored.notes {
                println!("  note: {note}");
            }
            Ok(())
        }
        WorktreeCmd::Archives { all } => {
            let manifests: Vec<_> =
                store.list().into_iter().filter(|m| all || m.restored_ms.is_none()).collect();
            if json_out {
                print_json(&json!({"archives": manifests}));
                return Ok(());
            }
            for m in &manifests {
                let kind = if m.archive_ref.is_some() { "archived" } else { "pushed" };
                println!(
                    "{}  {kind}  {}  {}  {}",
                    m.id,
                    m.branch.as_deref().unwrap_or("-"),
                    m.path.display(),
                    mib(m.freed)
                );
            }
            Ok(())
        }
    }
}

fn sweep(scope: &Scope, apply: bool, store: &Store, json_out: bool) -> Result<()> {
    let home = dirs::home_dir().ok_or_else(|| anyhow!("no home folder"))?;
    let roots = if scope.roots.is_empty() { default_roots(&home) } else { scope.roots.clone() };
    let options = Options {
        roots,
        sessions: sessions(&home),
        settings: Settings::default(),
        apply,
        pressure: scope.pressure.map(|p| match p {
            PressureArg::Normal => Pressure::Normal,
            PressureArg::High => Pressure::High,
            PressureArg::Critical => Pressure::Critical,
        }),
        only: scope.only.clone(),
    };
    let report = pass::run(&options, store).map_err(|e| anyhow!(e))?;
    if json_out {
        print_json(&json!(report));
    } else {
        print_report(&report, scope.all);
    }
    Ok(())
}

fn print_report(report: &Report, all: bool) {
    if let Some(disk) = report.disk {
        println!(
            "disk {:.0}% used, {} free ({:?})",
            disk.used_fraction() * 100.0,
            gib(disk.available),
            report.pressure
        );
    }
    for item in &report.items {
        if !all && item.verdict.action == Action::Keep {
            continue;
        }
        let word = match item.verdict.action {
            Action::Keep => "keep",
            Action::Trim => "trim",
            Action::Reclaim => "reclaim",
            Action::Archive => "archive",
        };
        let done = match &item.outcome {
            Some(o) if o.ok => format!("  [done, {}]", mib(o.freed)),
            Some(o) => format!("  [failed: {}]", o.error.as_deref().unwrap_or("?")),
            None => String::new(),
        };
        println!("{word:8} {}  {}{done}", item.path.display(), item.verdict.reason);
    }
    for error in &report.errors {
        println!("error    {error}");
    }
    let verb = if report.applied { "freed" } else { "would act on" };
    let acted =
        report.count(Action::Reclaim) + report.count(Action::Archive) + report.count(Action::Trim);
    println!(
        "{} worktrees: {} reclaim, {} archive, {} trim, {} keep; {verb} {}",
        report.items.len(),
        report.count(Action::Reclaim),
        report.count(Action::Archive),
        report.count(Action::Trim),
        report.count(Action::Keep),
        if report.applied { mib(report.freed) } else { format!("{acted}") }
    );
}

fn mib(bytes: u64) -> String {
    format!("{} MiB", bytes >> 20)
}

fn gib(bytes: u64) -> String {
    format!("{:.1} GiB", bytes as f64 / f64::from(1u32 << 30))
}

/// The folders agents' worktrees live under by default.
fn default_roots(home: &Path) -> Vec<PathBuf> {
    let mut roots =
        vec![home.join("Projects"), home.join("wt"), home.join("src"), home.join("code")];
    for parent in [home.join("wt"), home.join(".cmux/worktrees")] {
        if let Ok(entries) = std::fs::read_dir(&parent) {
            roots.extend(entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()));
        }
    }
    roots.retain(|root| root.is_dir());
    roots
}

/// A session file's fields this command reads.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionFile {
    name: String,
    cwd: PathBuf,
    status: String,
    #[serde(default)]
    updated_at: u64,
}

/// Every session of every acpmux state folder on this machine.
fn sessions(home: &Path) -> Vec<Session> {
    let mut homes = vec![crate::config::home(), crate::config::default_home()];
    for parent in [home.to_path_buf(), home.join(".cmux/chief")] {
        let Ok(entries) = std::fs::read_dir(&parent) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if parent == home && name.starts_with(".acpmux") {
                homes.push(path.clone());
                // A supervised daemon keeps one folder per host.
                if let Ok(children) = std::fs::read_dir(&path) {
                    homes.extend(children.flatten().map(|c| c.path()));
                }
            } else if parent != home {
                homes.push(path.join("acpmux"));
            }
        }
    }
    homes.sort();
    homes.dedup();
    let mut found = Vec::new();
    for state in homes {
        let Ok(entries) = std::fs::read_dir(state.join("sessions")) else { continue };
        let running = daemon_runs(&state);
        for entry in entries.flatten() {
            let Ok(bytes) = std::fs::read(entry.path().join("session.json")) else { continue };
            let Ok(file) = serde_json::from_slice::<SessionFile>(&bytes) else { continue };
            found.push(Session {
                name: file.name,
                cwd: file.cwd,
                open: running && file.status != "closed",
                updated_ms: file.updated_at,
            });
        }
    }
    found
}

/// Whether a daemon answers on the state folder's socket.
#[cfg(unix)]
fn daemon_runs(state: &Path) -> bool {
    std::os::unix::net::UnixStream::connect(state.join("acpmux.sock")).is_ok()
}

/// Windows: no socket to try, so every session not closed counts as open.
#[cfg(not(unix))]
fn daemon_runs(_state: &Path) -> bool {
    true
}

#[cfg(test)]
mod care_tests {
    use super::*;

    #[test]
    fn care_a_stopped_daemon_s_sessions_are_use_not_open() {
        let home = std::env::temp_dir()
            .join(format!("care-sessions-{}", cmux_worktree_care::inventory::now_ms()));
        let session = home.join(".acpmux-test/sessions/one");
        std::fs::create_dir_all(&session).unwrap();
        std::fs::write(
            session.join("session.json"),
            r#"{"name":"lane","cwd":"/w/a","status":"running","updatedAt":5}"#,
        )
        .unwrap();
        let found: Vec<_> = sessions(&home).into_iter().filter(|s| s.name == "lane").collect();
        assert_eq!(found.len(), 1);
        assert!(!found[0].open, "no daemon answers there");
        assert_eq!(found[0].updated_ms, 5);
        let _ = std::fs::remove_dir_all(home);
    }
}
