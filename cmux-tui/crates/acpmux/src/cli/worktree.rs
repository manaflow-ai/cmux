//! `acpmux worktree list|clean|remove|restore|archives`: the machine's
//! worktrees, cleaned up after the agents that made them
//! (`cmux-worktree-care`).
//!
//! - `list`: every linked worktree of the repositories under the roots and
//!   what a cleanup would do with it, and why.
//! - `clean`: does it. A worktree whose work lives only there is archived
//!   into git first (`refs/cmux/archive/<id>` and a bundle); a pushed one
//!   just goes; one still in use is never touched. `--dry-run` is `list`.
//! - `remove`: one worktree, now (`worktree_remove.rs`): refused with work
//!   only there unless `--discard`, never while a session runs in it.
//!
//! Paths follow the rule in `cmux_git::worktree`: a worktree prints under the
//! `~/.cmux/worktrees` link, and `--only` takes either spelling of a folder.
//! - `restore`: puts a reclaimed worktree back, by its folder, branch or
//!   archive id.
//! - `archives`: the manifests of reclaimed worktrees.
//!
//! The sessions come from every acpmux state folder on this machine
//! (`worktree_sessions.rs`); a process working in a worktree keeps it too.

use std::path::PathBuf;

use anyhow::{Result, anyhow};
use clap::{Subcommand, ValueEnum};
use cmux_worktree_care::Store;
use cmux_worktree_care::pass::{self, Options, Report};
use cmux_worktree_care::policy::{Action, Pressure, Settings};
use cmux_worktree_care::restore::restore;
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
    /// Remove one worktree now, with the branch cmux made for it: refused while
    /// it has uncommitted changes or unpushed commits (unless --discard) or a
    /// running session works in it.
    #[command(after_help = worktree_remove_help())]
    Remove {
        /// The worktree's folder, a session's name (the worktree it works in),
        /// or a worktree's name (`~/.cmux/worktrees/<project>/<name>`).
        target: String,
        /// Remove it even with uncommitted changes or commits found nowhere
        /// else: that work is lost.
        #[arg(long)]
        discard: bool,
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
    /// Only this worktree (repeatable; either spelling of a linked folder).
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

pub async fn run(cmd: WorktreeCmd, json_out: bool) -> Result<()> {
    let store = Store::open(Store::default_dir().ok_or_else(|| anyhow!("no home folder"))?)
        .map_err(|e| anyhow!(e))?;
    match cmd {
        WorktreeCmd::List(scope) => sweep(&scope, false, &store, json_out),
        WorktreeCmd::Clean { scope, dry_run } => sweep(&scope, !dry_run, &store, json_out),
        WorktreeCmd::Remove { target, discard } => {
            crate::cli::worktree_remove::run(&target, discard, json_out).await
        }
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
    let roots = if scope.roots.is_empty() {
        crate::worktree_sessions::default_roots(&home)
    } else {
        scope.roots.clone()
    };
    let options = Options {
        roots,
        sessions: crate::worktree_sessions::on_disk(&home, None),
        uses: crate::worktree_sessions::uses(crate::worktree_sessions::claude_homes(
            &home,
            &crate::worktree_sessions::state_configs(&home),
        )),
        open: std::sync::Arc::new(cmux_worktree_care::procs::open_inside),
        settings: Settings::default(),
        apply,
        pressure: scope.pressure.map(|p| match p {
            PressureArg::Normal => Pressure::Normal,
            PressureArg::High => Pressure::High,
            PressureArg::Critical => Pressure::Critical,
        }),
        only: scope.only.clone(),
        measure: !apply,
    };
    // Acting takes the machine's pass (`schedule`), which a daemon's pass
    // may hold: two passes over the same worktrees would archive one twice.
    // Only a pass over every worktree counts as the machine's last.
    let record = scope.only.is_empty() && scope.roots.is_empty();
    let claim = if apply {
        let now = cmux_worktree_care::inventory::now_ms();
        Some(cmux_worktree_care::schedule::claim(&store.dir, now, None, record).map_err(
            |refused| match refused {
                cmux_worktree_care::schedule::Refused::Unavailable(error) => anyhow!(error),
                _ => anyhow!("a worktree cleanup pass is already running on this machine"),
            },
        )?)
    } else {
        None
    };
    let report = pass::run(&options, store);
    if let Some(claim) = claim
        && let Err(error) = claim.finish(cmux_worktree_care::inventory::now_ms())
    {
        eprintln!("acpmux: could not record the cleanup pass: {error}");
    }
    let mut report = report.map_err(|e| anyhow!(e))?;
    // Printed under the `~/.cmux/worktrees` link, as cmux made them.
    for item in &mut report.items {
        item.path = cmux_git::worktree::shown(&home, &item.path);
    }
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
        let size = item.bytes.map(|b| format!("  ({})", mib(b))).unwrap_or_default();
        let done = match &item.outcome {
            Some(o) if o.ok => format!("  [done, {}]", mib(o.freed)),
            Some(o) => format!("  [failed: {}]", o.error.as_deref().unwrap_or("?")),
            None => String::new(),
        };
        println!("{word:8} {}  {}{size}{done}", item.path.display(), item.verdict.reason);
    }
    for error in &report.errors {
        println!("error    {error}");
    }
    let verb = if report.applied { "freed" } else { "would free" };
    println!(
        "{} worktrees: {} reclaim, {} archive, {} trim, {} keep; {verb} {}",
        report.items.len(),
        report.count(Action::Reclaim),
        report.count(Action::Archive),
        report.count(Action::Trim),
        report.count(Action::Keep),
        mib(if report.applied { report.freed } else { report.reclaimable })
    );
}

/// `acpmux worktree remove --help`'s closing text, in the locale's language
/// (LC_ALL, LC_MESSAGES, LANG; English unless it starts with `ja`).
fn worktree_remove_help() -> &'static str {
    let locale = ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
        .unwrap_or_default();
    if locale.to_ascii_lowercase().starts_with("ja") { REMOVE_HELP_JA } else { REMOVE_HELP_EN }
}

const REMOVE_HELP_EN: &str = "\
The worktree, its branch when cmux made it (acpmux new --worktree [--branch], cmux workspace create
--worktree), and the project folder in ~/.cmux/worktrees once it is empty. A branch that was there
before stays, and so does one that got commits found nowhere else. It is refused, changing nothing,
while a running session works in the worktree (stop it first: acpmux session stop NAME) and while
it has uncommitted changes or commits on no other branch or remote; the refusal names --discard,
which removes it anyway and loses that work. The main checkout is never removed.

Paths: a worktree prints as ~/.cmux/worktrees/<project>/<name> (on macOS a link to
~/.cmux/worktrees.noindex); either spelling, like /tmp and /private/tmp, names the same folder.";

const REMOVE_HELP_JA: &str = "\
ワークツリーと、cmux が作ったブランチ (acpmux new --worktree [--branch]、cmux workspace create
--worktree)、空になった ~/.cmux/worktrees のプロジェクトフォルダーを削除します。前からあったブランチと、
ほかのどこにもないコミットができたブランチは残ります。実行中のセッションがそのワークツリーで作業している
とき (先に acpmux session stop NAME で止めてください)、またはコミットされていない変更や、ほかのどの
ブランチにもリモートにもないコミットがあるときは、何も変えずに拒否します。そのメッセージは --discard を
示します。--discard はその作業を失って削除します。メインのチェックアウトは削除しません。

パス: ワークツリーは ~/.cmux/worktrees/<project>/<name> と表示されます (macOS では
~/.cmux/worktrees.noindex へのリンクです)。どちらの書き方も、/tmp と /private/tmp と同じように、
同じフォルダーを指します。";

fn mib(bytes: u64) -> String {
    format!("{} MiB", bytes >> 20)
}

fn gib(bytes: u64) -> String {
    format!("{:.1} GiB", bytes as f64 / f64::from(1u32 << 30))
}
