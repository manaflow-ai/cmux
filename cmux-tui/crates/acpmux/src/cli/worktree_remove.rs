//! `acpmux worktree remove TARGET [--discard]`: removes one worktree an agent
//! worked in, now, with the rules the app's `git.worktree.remove` follows
//! (`cmux_git::worktree`, shared with cmux-tui):
//!
//! - TARGET is the worktree's folder (either spelling of a link:
//!   `~/.cmux/worktrees/<project>/<name>` or `~/.cmux/worktrees.noindex/...`),
//!   a session's name (the worktree it works in), or a worktree's name (the
//!   folder `~/.cmux/worktrees/<project>/<name>`, when one project has it).
//! - It is refused, changing nothing, while a running session works in it
//!   (stop it first), and while the worktree has uncommitted changes or
//!   commits on no other branch or remote, unless `--discard`; the refusal
//!   says what keeps it and names `--discard`.
//! - The folder goes (`git worktree remove`, from the main checkout, git
//!   hardened as `subsession_worktree.rs` runs it), then its branch when cmux
//!   made it (`cmux new --worktree`, `acpmux new --worktree [--branch]`) and it
//!   got no commits found nowhere else, then the empty project folder in
//!   `~/.cmux/worktrees`. The main checkout is never removed.
//!
//! It runs in this process, like `worktree clean`: no daemon needed.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use cmux_git::Repository;
use cmux_git::worktree::{self as shared, KeptWork};
use cmux_worktree_care::policy::Session;
use serde_json::{Value, json};

use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;

/// How long the removal's git runs may take in all.
const DEADLINE: Duration = Duration::from_secs(120);

/// What one removal did.
struct Removed {
    root: PathBuf,
    main_root: PathBuf,
    branch: Option<String>,
    branch_deleted: bool,
    /// Why the branch stayed, when it did.
    branch_kept: Option<&'static str>,
    project_folder_removed: bool,
}

pub fn run(target: &str, discard: bool, json_out: bool) -> Result<()> {
    let home = dirs::home_dir().ok_or_else(|| anyhow!("no home folder"))?;
    let sessions = crate::worktree_sessions::on_disk(&home, None);
    let folder = locate(&home, target, &sessions)?;
    let removed = remove(&home, &folder, &sessions, discard)?;
    let shown = shared::shown(&home, &removed.root);
    if json_out {
        print_json(&json!({
            "root": shown,
            "mainRoot": removed.main_root,
            "branch": removed.branch,
            "branchDeleted": removed.branch_deleted,
            "branchKept": removed.branch_kept,
            "projectFolderRemoved": removed.project_folder_removed,
        }));
        return Ok(());
    }
    println!("removed {}", shown.display());
    match (&removed.branch, removed.branch_deleted) {
        (Some(branch), true) => println!("  branch {branch} deleted"),
        (Some(branch), false) => {
            println!("  branch {branch} kept: {}", removed.branch_kept.unwrap_or("it stays"));
        }
        (None, _) => {}
    }
    if removed.project_folder_removed
        && let Some(project) = shown.parent()
    {
        println!("  empty project folder {} removed", project.display());
    }
    Ok(())
}

/// The folder TARGET names: a folder, a session's folder, or a worktree's name.
fn locate(home: &Path, target: &str, sessions: &[Session]) -> Result<PathBuf> {
    if target.is_empty() {
        return Err(usage("give the worktree's folder, a session's name or a worktree's name"));
    }
    let expanded = match target.strip_prefix("~/") {
        Some(rest) => home.join(rest),
        None => PathBuf::from(target),
    };
    if expanded.is_absolute() || target.contains('/') || target == "." || target == ".." {
        let path =
            if expanded.is_absolute() { expanded } else { std::env::current_dir()?.join(expanded) };
        if path.is_dir() {
            return Ok(path);
        }
        return Err(usage(&format!("{} is no folder", path.display())));
    }
    if let Some(session) = sessions.iter().filter(|s| s.name == target).max_by_key(|s| s.updated_ms)
        && session.cwd.is_dir()
    {
        return Ok(session.cwd.clone());
    }
    let root = cmux_git::worktree_root::worktree_root_path(home);
    let mut found: Vec<PathBuf> = std::fs::read_dir(&root)
        .into_iter()
        .flatten()
        .flatten()
        .map(|project| root.join(project.file_name()).join(target))
        .filter(|folder| folder.is_dir())
        .collect();
    found.sort();
    match found.as_slice() {
        [one] => Ok(one.clone()),
        [] => Err(usage(&format!(
            "no session or worktree is named {target}: give the worktree's folder \
             (`acpmux worktree list --all` lists them)"
        ))),
        many => {
            let listed: Vec<String> = many.iter().map(|p| p.display().to_string()).collect();
            Err(usage(&format!(
                "{target} names {} worktrees; give one folder: {}",
                many.len(),
                listed.join(", ")
            )))
        }
    }
}

fn usage(message: &str) -> anyhow::Error {
    AppError::usage(message).into()
}

/// A refusal: nothing was changed.
fn refused(reason: &str, message: String, data: Value) -> anyhow::Error {
    let mut data = data;
    data["reason"] = json!(reason);
    AppError::new(Code::Runtime, reason, message).with_data(data).into()
}

fn remove(home: &Path, folder: &Path, sessions: &[Session], discard: bool) -> Result<Removed> {
    let by = Instant::now() + DEADLINE;
    let repository = Repository::open_within(folder, by)
        .map_err(|e| anyhow!("{}: {e}", shared::shown(home, folder).display()))?;
    let root = repository.root.clone();
    let shown = shared::shown(home, &root);
    let Some(main_root) = repository.main_checkout() else {
        return Err(refused(
            "not_a_worktree",
            format!(
                "{} is the main checkout, not a linked worktree: it is never removed",
                shown.display()
            ),
            json!({"root": shown}),
        ));
    };
    let inside = shared::resolved(&root);
    if let Some(session) =
        sessions.iter().find(|s| s.open && shared::resolved(&s.cwd).starts_with(&inside))
    {
        return Err(refused(
            "in_use",
            format!(
                "the session {name} still works in {}: stop it first with `acpmux session stop \
                 {name}`, then remove the worktree",
                shown.display(),
                name = session.name
            ),
            json!({"root": shown, "session": session.name}),
        ));
    }
    let branch = head_branch(&repository);
    let branch_goes =
        branch.as_deref().is_some_and(|b| shared::branch_goes_with_worktree(&repository, b));
    if !discard
        && let Some(kept) = shared::work_kept(&repository, branch.as_deref(), branch_goes)
            .map_err(|e| anyhow!("{}: {e}", shown.display()))?
    {
        return Err(kept_refusal(&kept, &shown));
    }
    let listed = registered(&main_root, &root, by)?
        .ok_or_else(|| anyhow!("{} is not a worktree git lists", shown.display()))?;
    let mut remove = vec!["worktree", "remove"];
    if discard {
        remove.push("--force");
    }
    remove.push(listed.as_str());
    crate::subsession_worktree::git_repo_write_by(&main_root, &remove, by)
        .map_err(|e| anyhow!("{}: {e}", shown.display()))?;
    let (branch_deleted, branch_kept) = match branch.as_deref() {
        None => (false, None),
        Some(_) if !branch_goes => (false, Some("it was there before the worktree")),
        Some(branch) => delete_branch(&main_root, branch, discard, by)?,
    };
    let project_folder_removed = shared::remove_empty_project_folder(home, &root);
    Ok(Removed { root, main_root, branch, branch_deleted, branch_kept, project_folder_removed })
}

/// The refusal for work the removal keeps; its message names `--discard`.
fn kept_refusal(kept: &KeptWork, shown: &Path) -> anyhow::Error {
    let data = match kept {
        KeptWork::Uncommitted { files, count, .. } => json!({"files": files, "count": count}),
        KeptWork::Unpushed { branch, count } => json!({"branch": branch, "count": count}),
    };
    let mut data = data;
    data["root"] = json!(shown);
    refused(kept.reason(), format!("{}: {}", shown.display(), kept.message()), data)
}

/// The branch HEAD is on; None when detached.
fn head_branch(repository: &Repository) -> Option<String> {
    // The full ref: `--short` names `heads/<b>` when a tag shares the name.
    let output = repository
        .run(&["symbolic-ref", "--quiet", "HEAD"], cmux_git::MAX_SMALL_OUTPUT_BYTES)
        .ok()?;
    let head = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    head.strip_prefix("refs/heads/").map(str::to_owned)
}

/// The path git lists for the worktree at `root`, links resolved.
fn registered(main_root: &Path, root: &Path, by: Instant) -> Result<Option<String>> {
    let listed =
        crate::subsession_worktree::git_by(main_root, &["worktree", "list", "--porcelain"], by)
            .map_err(|e| anyhow!(e))?;
    let wanted = shared::resolved(root);
    Ok(listed
        .lines()
        .filter_map(|line| line.strip_prefix("worktree "))
        .find(|path| shared::resolved(Path::new(path)) == wanted)
        .map(str::to_owned))
}

/// Deletes `branch` once its worktree is gone, unless it got commits found
/// nowhere else (then it stays, unless `discard`); whether it went, and why
/// it stayed.
fn delete_branch(
    main_root: &Path,
    branch: &str,
    discard: bool,
    by: Instant,
) -> Result<(bool, Option<&'static str>)> {
    let main = Repository::open_within(main_root, by).map_err(|e| anyhow!(e.to_string()))?;
    let reference = format!("refs/heads/{branch}");
    if main.commit(&reference).is_none() {
        return Ok((true, None));
    }
    if !discard && shared::commits_only_on(&main, &reference, Some(branch))? > 0 {
        return Ok((false, Some("it got commits found nowhere else")));
    }
    match crate::subsession_worktree::git_repo_write_by(main_root, &["branch", "-D", branch], by) {
        Ok(_) => Ok((true, None)),
        Err(_) => Ok((false, Some("git kept it (it is checked out elsewhere)"))),
    }
}
