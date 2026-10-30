//! What `acpmux session move` decides before it touches anything (`cli/run/session_move.rs`):
//! whether a chat may move, and where its folder goes on the target. Pure, so the rules are
//! tested without a daemon, ssh or git.
//!
//! - A chat whose turn is running moves only with `--interrupt`; one being moved, or one that
//!   moved away already, never.
//! - A folder in a git checkout on a branch becomes a fresh worktree of the same branch on the
//!   target (`Folder::Worktree`), its subfolder kept. The branch is pushed first, so the target
//!   checks out what this machine has. A detached HEAD or a checkout with no `origin` is refused;
//!   so are uncommitted changes, unless `--leave-dirty` (they then stay on this machine and the
//!   move's record says so).
//! - Any other folder under this machine's home maps to the same path under the target's home
//!   (`~/Projects/x` stays `~/Projects/x`), made there if missing (`Folder::Plain`). Its files do
//!   not move. A folder outside the home is refused: pass `--cwd`.
//! - `--cwd PATH` (`target_cwd`) runs the chats in PATH on the target as it is there, for any
//!   folder: no worktree is made and no branch pushed.

use serde_json::Value;
use std::path::{Component, Path, PathBuf};

/// A chat folder's git checkout, as this machine sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Checkout {
    /// The checkout's top folder (`git rev-parse --show-toplevel`).
    pub top: PathBuf,
    /// The branch checked out; None for a detached HEAD.
    pub branch: Option<String>,
    /// `origin`'s URL; None when it has no `origin`.
    pub origin: Option<String>,
    /// It has uncommitted changes (tracked or untracked, ignoring ignored files).
    pub dirty: bool,
}

/// Where the chat's folder goes on the target.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Folder {
    /// The same path under the target's home.
    Plain { cwd: String },
    /// A worktree of `branch` of `repo` (`owner/name`) on the target, then `subdir` inside it.
    Worktree { repo: String, url: String, branch: String, subdir: String, dirty: bool },
}

/// Whether the chat `summary` (`_acpmux/info`) may move now; the reason when not.
pub(crate) fn refusal(summary: &Value, interrupt: bool) -> Option<String> {
    if summary.get("movedTo").is_some_and(|m| !m.is_null()) {
        let to = moved_to_text(&summary["movedTo"]);
        return Some(format!("it moved away already ({to}); it never runs here again"));
    }
    if summary["moving"] == true {
        return Some("it is being moved already".into());
    }
    let running = summary.get("turn").is_some_and(|t| !t.is_null())
        || summary["status"].as_str() == Some("running");
    if running && !interrupt {
        return Some("a turn is running; pass --interrupt to stop it and move".into());
    }
    None
}

/// `HOST/SESSION` of a `movedTo` record, for a sentence.
pub(crate) fn moved_to_text(to: &Value) -> String {
    let host = to["host"].as_str().unwrap_or("another daemon");
    match to["sessionId"].as_str() {
        Some(id) => format!("to {host}/{id}"),
        None => format!("to {host}"),
    }
}

/// `owner/name` of a GitHub-style remote URL: `https://github.com/o/n(.git)`,
/// `git@github.com:o/n(.git)`, `ssh://git@github.com/o/n`. None for anything else.
pub(crate) fn repo_slug(url: &str) -> Option<String> {
    let url = url.trim();
    let path = if let Some(rest) = url.split_once("://").map(|(_, r)| r) {
        rest.split_once('/')?.1
    } else {
        // scp-like `user@host:path`.
        let (head, path) = url.split_once(':')?;
        if head.contains('/') {
            return None;
        }
        path
    };
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let mut parts = path.split('/');
    let (owner, name) = (parts.next()?, parts.next()?);
    let plain = |s: &str| {
        !s.is_empty()
            && !s.starts_with(['-', '.'])
            && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    };
    (parts.next().is_none() && plain(owner) && plain(name)).then(|| format!("{owner}/{name}"))
}

/// A branch name safe to hand a remote script as one line: git's own rules (no `..`, no
/// leading `-`, no control or space characters), nothing a shell or git reads as an option.
pub(crate) fn plain_branch(branch: &str) -> bool {
    !branch.is_empty()
        && !branch.starts_with(['-', '/', '.'])
        && !branch.ends_with(['/', '.'])
        && !branch.ends_with(".lock")
        && !branch.contains("..")
        && !branch.contains("//")
        && !branch.contains("@{")
        && branch.bytes().all(|b| b.is_ascii_alphanumeric() || b"/._-+".contains(&b))
}

/// `path` relative to `base`, when it is `base` or inside it, with no `..` on the way.
fn under(path: &Path, base: &Path) -> Option<PathBuf> {
    let rel = path.strip_prefix(base).ok()?;
    rel.components().all(|c| matches!(c, Component::Normal(_))).then(|| rel.to_path_buf())
}

/// Where the folder `cwd` of a chat on this machine (home `home`) goes on a target whose home
/// is `target_home`; `checkout` is its git checkout, if it is in one. `target_cwd` (`--cwd`)
/// names the folder there outright.
pub(crate) fn plan_folder(
    cwd: &Path,
    home: &Path,
    checkout: Option<&Checkout>,
    target_home: &str,
    leave_dirty: bool,
    target_cwd: Option<&str>,
) -> Result<Folder, String> {
    if let Some(there) = target_cwd {
        let plain = there.starts_with('/')
            && super::hosts::plain_path(there)
            && !there.split('/').any(|c| c == "..");
        if !plain {
            return Err(format!("--cwd {there:?} is not a plain absolute path"));
        }
        return Ok(Folder::Plain { cwd: there.to_owned() });
    }
    if !target_home.starts_with('/') {
        return Err(format!("the target's home {target_home:?} is not an absolute path"));
    }
    if let Some(c) = checkout {
        let subdir = under(cwd, &c.top).ok_or_else(|| {
            format!("{} is not inside its checkout {}", cwd.display(), c.top.display())
        })?;
        let Some(branch) = c.branch.as_deref() else {
            return Err(format!(
                "{} is on a detached HEAD: check out a branch first",
                c.top.display()
            ));
        };
        if !plain_branch(branch) {
            return Err(format!("branch {branch:?} is not a plain branch name"));
        }
        let Some(url) = c.origin.as_deref() else {
            return Err(format!("{} has no origin remote to push {branch} to", c.top.display()));
        };
        let repo = repo_slug(url)
            .ok_or_else(|| format!("origin of {} is not an owner/name remote", c.top.display()))?;
        if c.dirty && !leave_dirty {
            return Err(format!(
                "{} has uncommitted changes: commit them, or pass --leave-dirty to move without them",
                c.top.display()
            ));
        }
        let subdir = subdir.to_string_lossy().into_owned();
        if !subdir.is_empty() && !super::hosts::plain_path(&format!("/{subdir}")) {
            return Err(format!("subfolder {subdir:?} is not a plain path"));
        }
        return Ok(Folder::Worktree {
            repo,
            url: url.to_owned(),
            branch: branch.to_owned(),
            subdir,
            dirty: c.dirty,
        });
    }
    let rel = under(cwd, home).ok_or_else(|| {
        format!("{} is outside this machine's home: pass --cwd for the target", cwd.display())
    })?;
    let base = match target_home.trim_end_matches('/') {
        "" => "/",
        base => base,
    };
    // The home itself is the target's home, with no trailing `/`.
    let target =
        if rel.as_os_str().is_empty() { PathBuf::from(base) } else { Path::new(base).join(rel) };
    let cwd = target.to_string_lossy().into_owned();
    if !super::hosts::plain_path(&cwd) {
        return Err(format!("{cwd:?} is not a plain path"));
    }
    Ok(Folder::Plain { cwd })
}

#[cfg(test)]
#[path = "session_move_plan_tests.rs"]
mod tests;
