//! `acpmux worktree remove TARGET [--discard]`: removes one worktree an agent
//! worked in, now, with the rules the app's `git.worktree.remove` follows
//! (`cmux_git::worktree`, shared with cmux-tui):
//!
//! - TARGET is the worktree's folder (either spelling of a link:
//!   `~/.cmux/worktrees/<project>/<name>` or `~/.cmux/worktrees.noindex/...`),
//!   a session's name (the worktree it works in), or a worktree's name (the
//!   folder `~/.cmux/worktrees/<project>/<name>`, when one project has it).
//! - It is refused, changing nothing, while an open session works in it
//!   (stop it first): the running daemon's live sessions (a live session's
//!   `session.json` may not be written yet) and those on disk. Also while the worktree has uncommitted changes or
//!   commits on no other branch or remote, unless `--discard`; the refusal
//!   says what keeps it and names `--discard`.
//! - The folder goes (`git worktree remove`, from the main checkout, git
//!   hardened as `subsession_worktree.rs` runs it), then its branch when cmux
//!   made it (`cmux new --worktree`, `acpmux new --worktree [--branch]`) and it
//!   got no commits found nowhere else, then the empty project folder in
//!   `~/.cmux/worktrees`. The main checkout is never removed.
//!
//! It runs in this process, like `worktree clean`: no daemon needed.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use cmux_git::Repository;
use cmux_git::worktree::{self as shared, KeptWork};
use cmux_json::JsonSet as _;
use cmux_worktree_care::policy::Session;
use serde_json::{Value, json};

use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;
use crate::rpc::method;

/// Whether this command speaks Japanese (LC_ALL, LC_MESSAGES, LANG; the
/// first set starts with `ja`); else English.
fn japanese() -> bool {
    crate::cli::sender::japanese(|key| std::env::var(key).ok())
}

/// `en` or `ja`, in this command's language.
fn say(en: String, ja: String) -> String {
    if japanese() { ja } else { en }
}

/// How long the removal's git runs may take in all.
const DEADLINE: Duration = Duration::from_secs(120);

/// How long the running daemon may take to list its live sessions.
const LIST_WAIT: Duration = Duration::from_secs(30);

/// At most this many pages of the daemon's live sessions.
const MAX_PAGES: usize = 64;

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

pub async fn run(target: &str, discard: bool, json_out: bool) -> Result<()> {
    let home = dirs::home_dir().ok_or_else(|| {
        anyhow!(say("no home folder".into(), "ホームフォルダーがありません".into()))
    })?;
    let sessions = sessions(&home).await?;
    let folder = locate(&home, target, &sessions)?;
    let removed = remove(&home, &folder, &sessions, discard)?;
    // Printed as the person gave the folder; git gives them links resolved.
    let shown = shared::as_given(&home, &folder, &removed.root);
    if json_out {
        print_json(&json!({
            "root": shown,
            "mainRoot": shared::as_given(&home, &folder, &removed.main_root),
            "branch": removed.branch,
            "branchDeleted": removed.branch_deleted,
            "branchKept": removed.branch_kept,
            "projectFolderRemoved": removed.project_folder_removed,
        }));
        return Ok(());
    }
    let ja = japanese();
    let line = |en: String, japanese: String| println!("{}", if ja { japanese } else { en });
    line(format!("removed {}", shown.display()), format!("{} を削除しました", shown.display()));
    match (&removed.branch, removed.branch_deleted) {
        (Some(branch), true) => {
            line(
                format!("  branch {branch} deleted"),
                format!("  ブランチ {branch} を削除しました"),
            );
        }
        (Some(branch), false) => {
            let why = removed.branch_kept.unwrap_or(KEPT_STAYS);
            line(
                format!("  branch {branch} kept: {why}"),
                format!("  ブランチ {branch} は残しました: {}", kept_ja(why)),
            );
        }
        (None, _) => {}
    }
    if removed.project_folder_removed
        && let Some(project) = shown.parent()
    {
        line(
            format!("  empty project folder {} removed", project.display()),
            format!("  空のプロジェクトフォルダー {} を削除しました", project.display()),
        );
    }
    Ok(())
}

/// Every session on this machine: the running daemon's live ones, and those
/// in the state folders on disk (this home's own only when no daemon runs).
async fn sessions(home: &Path) -> Result<Vec<Session>> {
    let Some(mut live) = live_sessions().await? else {
        return Ok(crate::worktree_sessions::on_disk(home, None));
    };
    live.extend(crate::worktree_sessions::on_disk(home, Some(&crate::config::home())));
    Ok(live)
}

/// The sessions this home's running daemon has open on this machine; None
/// when no daemon runs. A daemon that runs but does not list them is an
/// error: without the list, a live session's worktree could be removed.
async fn live_sessions() -> Result<Option<Vec<Session>>> {
    let Ok(client) = crate::daemon::connect_running().await else { return Ok(None) };
    let unread = |why: String| {
        anyhow!(say(
            format!("could not read the running acpmux sessions ({why}): try again"),
            format!(
                "実行中の acpmux のセッションを読めませんでした ({why})。もう一度実行してください"
            ),
        ))
    };
    let mut params = json!({"localOnly": true, "excludeStatus": ["closed"]});
    let mut cursors = HashSet::new();
    let mut found = Vec::new();
    for _ in 0..MAX_PAGES {
        let page =
            tokio::time::timeout(LIST_WAIT, client.request(method::MUX_SESSIONS, params.clone()))
                .await
                .map_err(|_| unread("no answer".into()))?
                .map_err(|e| unread(e.to_string()))?;
        for row in page.get("sessions").and_then(Value::as_array).into_iter().flatten() {
            let Some(cwd) = row.get("cwd").and_then(Value::as_str) else { continue };
            found.push(Session {
                name: row.get("name").and_then(Value::as_str).unwrap_or_default().to_owned(),
                cwd: PathBuf::from(cwd),
                open: true,
                updated_ms: row.get("updatedAt").and_then(Value::as_u64).unwrap_or_default(),
            });
        }
        match page.get("nextCursor").and_then(Value::as_str) {
            Some(cursor) if !cursor.is_empty() && cursors.insert(cursor.to_owned()) => {
                params.set("cursor", json!(cursor));
            }
            _ => return Ok(Some(found)),
        }
    }
    Err(unread(format!("more than {MAX_PAGES} pages")))
}

/// The folder TARGET names: a folder, a session's folder, or a worktree's name.
fn locate(home: &Path, target: &str, sessions: &[Session]) -> Result<PathBuf> {
    if target.is_empty() {
        return Err(usage(&say(
            "give the worktree's folder, a session's name or a worktree's name".into(),
            "ワークツリーのフォルダー、セッション名、またはワークツリー名を指定してください".into(),
        )));
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
        return Err(usage(&say(
            format!("{} is no folder", path.display()),
            format!("{} はフォルダーではありません", path.display()),
        )));
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
        [] => Err(usage(&say(
            format!(
                "no session or worktree is named {target}: give the worktree's folder \
                 (`acpmux worktree list --all` lists them)"
            ),
            format!(
                "{target} という名前のセッションもワークツリーもありません。ワークツリーのフォルダーを\
                 指定してください (`acpmux worktree list --all` で一覧を表示します)"
            ),
        ))),
        many => {
            let listed: Vec<String> = many.iter().map(|p| p.display().to_string()).collect();
            Err(usage(&say(
                format!(
                    "{target} names {} worktrees; give one folder: {}",
                    many.len(),
                    listed.join(", ")
                ),
                format!(
                    "{target} に当たるワークツリーが {} 個あります。フォルダーを 1 つ指定してください: {}",
                    many.len(),
                    listed.join(", ")
                ),
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
    data.set("reason", json!(reason));
    AppError::new(Code::Runtime, reason, message).with_data(data).into()
}

fn remove(home: &Path, folder: &Path, sessions: &[Session], discard: bool) -> Result<Removed> {
    let by = Instant::now() + DEADLINE;
    let repository =
        Repository::open_within(folder, by).map_err(|e| anyhow!("{}: {e}", folder.display()))?;
    let root = repository.root.clone();
    let shown = shared::as_given(home, folder, &root);
    let Some(main_root) = repository.main_checkout() else {
        return Err(refused(
            "not_a_worktree",
            say(
                format!(
                    "{} is the main checkout, not a linked worktree: it is never removed",
                    shown.display()
                ),
                format!(
                    "{} はメインのチェックアウトで、リンクされたワークツリーではありません。削除しません",
                    shown.display()
                ),
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
            say(
                format!(
                    "the session {name} still works in {}: stop it first with `acpmux session stop \
                     {name}`, then remove the worktree",
                    shown.display(),
                    name = session.name
                ),
                format!(
                    "セッション {name} がまだ {} で作業しています。先に `acpmux session stop {name}` で\
                     止めてから、ワークツリーを削除してください",
                    shown.display(),
                    name = session.name
                ),
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
    let listed = registered(&main_root, &root, by)?.ok_or_else(|| {
        anyhow!(say(
            format!("{} is not a worktree git lists", shown.display()),
            format!("{} は git が一覧に出すワークツリーではありません", shown.display()),
        ))
    })?;
    let mut remove = vec!["worktree", "remove"];
    if discard {
        remove.push("--force");
    }
    remove.push(listed.as_str());
    crate::subsession_worktree::git_repo_write_by(&main_root, &remove, by)
        .map_err(|e| anyhow!("{}: {e}", shown.display()))?;
    let (branch_deleted, branch_kept) = match branch.as_deref() {
        None => (false, None),
        Some(_) if !branch_goes => (false, Some(KEPT_BEFORE)),
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
    data.set("root", json!(shown));
    let message = say(kept.message(), kept.japanese());
    refused(kept.reason(), format!("{}: {message}", shown.display()), data)
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
        return Ok((false, Some(KEPT_COMMITS)));
    }
    match crate::subsession_worktree::git_repo_write_by(main_root, &["branch", "-D", branch], by) {
        Ok(_) => Ok((true, None)),
        Err(_) => Ok((false, Some(KEPT_ELSEWHERE))),
    }
}

/// Why a branch stayed (`branchKept` in `--json`, English for scripts).
const KEPT_BEFORE: &str = "it was there before the worktree";
const KEPT_COMMITS: &str = "it got commits found nowhere else";
const KEPT_ELSEWHERE: &str = "git kept it (it is checked out elsewhere)";
const KEPT_STAYS: &str = "it stays";

/// A reason a branch stayed, in Japanese.
fn kept_ja(why: &str) -> &'static str {
    match why {
        KEPT_BEFORE => "ワークツリーより前からあったブランチです",
        KEPT_COMMITS => "ほかにないコミットがあります",
        KEPT_ELSEWHERE => "git が残しました (ほかでチェックアウトされています)",
        _ => "残ります",
    }
}
