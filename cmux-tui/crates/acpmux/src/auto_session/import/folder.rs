//! A snapshot's folder on this machine. Blocking: git and file work, run off the async threads.
//!
//! A git folder is `session_move_carry`'s form: `base`, a commit the remote has; a git bundle of
//! the local commits past it (its first head is the chat's `HEAD`); and one binary patch of the
//! uncommitted work, applied on top.
//!
//! - New here: an empty repository of `remote`, `base` fetched from it, the bundle fetched on
//!   top, `branch` checked out at the bundle's head, the patch applied. A plain folder is its
//!   tar, unpacked.
//! - Already here (a handback into the laptop's own folder): the folder becomes the snapshot's.
//!   What it held before is not lost: its commit and its uncommitted tracked changes are kept
//!   under `refs/cmux/auto/before/<label>` first, and files git does not track stay unless the
//!   snapshot has a file of the same path. A patch that does not apply puts the folder back.
//!
//! A new folder that cannot be finished is removed.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use cmux_auto_session::wire::Cwd;

use crate::home_fs;

/// Where a folder keeps the last snapshot's base: a commit the chat's remote has.
pub(crate) const BASE_REF: &str = "refs/cmux/auto/base";

pub(super) fn place(
    dir: &Path,
    fresh: bool,
    cwd: &Cwd,
    first: &[u8],
    patch: &[u8],
    label: &str,
) -> Result<(), String> {
    if fresh {
        make_empty(dir)?;
    } else if !dir.is_dir() {
        return Err(format!("the chat's folder {} is gone", dir.display()));
    }
    let placed = match cwd {
        Cwd::Folder { .. } => unpack(dir, first),
        Cwd::Git { remote, branch, base, .. } => {
            Git { remote, branch, base, bundle: first, patch }.lay_out(dir, fresh, label)
        }
    };
    if placed.is_err() && fresh {
        let _ = home_fs::remove_dir_all(dir);
    }
    placed
}

/// Removes a folder this import made, when what came after it failed. Best effort.
pub(super) async fn discard(dir: PathBuf) {
    let _ = tokio::task::spawn_blocking(move || home_fs::remove_dir_all(&dir)).await;
}

/// A folder for a chat started in the Cloud: `remote` cloned at `branch`, or at the remote's
/// default branch with `branch` made there when the remote has none of that name.
pub(super) fn clone(dir: &Path, remote: &str, branch: &str) -> Result<(), String> {
    plain(remote, "the repository")?;
    plain(branch, "the branch")?;
    make_empty(dir)?;
    let cloned = git(dir, &["clone", "-q", "--branch", branch, "--", remote, "."])
        .or_else(|_| {
            git(dir, &["clone", "-q", "--", remote, "."])?;
            git(dir, &["checkout", "-q", "-b", branch])
        })
        .map(|_| ());
    if cloned.is_err() {
        let _ = home_fs::remove_dir_all(dir);
    }
    cloned
}

/// Git in `dir` for a snapshot's folder. It reaches the remote with the machine's own git
/// credentials, never asks at a terminal, gives up on a stalled transfer, and runs no hook of
/// the repository.
fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"])
        .args(["-c", "submodule.recurse=false", "-c", "http.lowSpeedLimit=1000"])
        .args(["-c", "http.lowSpeedTime=60"])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_SSH_COMMAND", "ssh -oBatchMode=yes")
        .env("GIT_LFS_SKIP_SMUDGE", "1")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("git did not start: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("git {} failed: {}", args.first().unwrap_or(&""), err.trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// `dir` exists and is empty. A folder with files in it is someone's: it is never reused.
fn make_empty(dir: &Path) -> Result<(), String> {
    home_fs::create_dirs(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    let mut entries = std::fs::read_dir(dir).map_err(|e| format!("read {}: {e}", dir.display()))?;
    match entries.next() {
        None => Ok(()),
        Some(_) => Err(format!("the chat's folder {} already has files", dir.display())),
    }
}

/// A value git takes as an argument, never as an option.
fn plain(value: &str, what: &str) -> Result<(), String> {
    if value.is_empty() || value.starts_with('-') || value.chars().any(char::is_control) {
        return Err(format!("{what} {value:?} is not one git can take"));
    }
    Ok(())
}

fn unpack(dir: &Path, tar: &[u8]) -> Result<(), String> {
    if tar.is_empty() {
        return Ok(());
    }
    let mut archive = tar::Archive::new(std::io::Cursor::new(tar));
    archive.unpack(dir).map_err(|e| format!("unpack the folder: {e}"))
}

struct Git<'a> {
    remote: &'a str,
    branch: &'a str,
    base: &'a str,
    bundle: &'a [u8],
    patch: &'a [u8],
}

impl Git<'_> {
    /// The snapshot's commits and uncommitted work, checked out at `dir`.
    fn lay_out(&self, dir: &Path, fresh: bool, label: &str) -> Result<(), String> {
        plain(self.remote, "the repository")?;
        plain(self.base, "the base commit")?;
        if !self.branch.is_empty() {
            plain(self.branch, "the branch")?;
        }
        let scratch = tempfile::tempdir().map_err(|e| format!("a temp folder: {e}"))?;
        let before = if fresh {
            git(dir, &["init", "-q"])?;
            git(dir, &["remote", "add", "origin", self.remote])?;
            None
        } else {
            Some(Before::keep(dir, label)?)
        };
        let head = self.fetch_commits(dir, scratch.path())?;
        let mut checkout = vec!["checkout", "-q"];
        if !fresh {
            checkout.push("-f");
        }
        match self.branch {
            // A detached checkout: the copy's side names it `HEAD` (`export/folder.rs`).
            "" | "HEAD" => checkout.extend(["--detach", head.as_str()]),
            branch => checkout.extend(["-B", branch, head.as_str()]),
        }
        git(dir, &checkout)?;
        self.keep_base(dir);
        if self.patch.is_empty() {
            return Ok(());
        }
        let file = scratch.path().join("patch");
        std::fs::write(&file, self.patch).map_err(|e| format!("write the patch: {e}"))?;
        let file = file.to_string_lossy();
        let applied = git(dir, &["apply", "--binary", "--whitespace=nowarn", &file]);
        if let (Err(_), Some(before)) = (&applied, &before) {
            before.as_it_was(dir);
        }
        applied.map(|_| ()).map_err(|e| format!("the snapshot's patch does not apply: {e}"))
    }

    /// Keeps the base under [`BASE_REF`]: a commit the remote has. A new folder fetched it by
    /// its id, which leaves no branch of the remote behind, and the chat's next copy from this
    /// folder looks for a commit the remote has (`export/folder.rs` `base_of`). With none the
    /// folder would go back as a tar, and the commits made here would not come home as
    /// commits. Best effort.
    fn keep_base(&self, dir: &Path) {
        let _ = git(dir, &["update-ref", BASE_REF, self.base]);
    }

    /// Brings the snapshot's commits into the repository at `dir`; answers the chat's `HEAD`.
    fn fetch_commits(&self, dir: &Path, scratch: &Path) -> Result<String, String> {
        // The base comes from the remote: by its id where the remote gives commits by id, else
        // with the branch it is on. A remote that cannot be reached is no failure yet: a
        // bundle that needs no base, or a folder that has the base already, still checks out.
        let from_remote =
            git(dir, &["fetch", "-q", "--no-tags", "origin", self.base]).or_else(|e| {
                match self.branch {
                    "" => Err(e),
                    branch => git(dir, &["fetch", "-q", "--no-tags", "origin", branch]),
                }
            });
        if self.bundle.is_empty() {
            let commit = format!("{}^{{commit}}", self.base);
            return match git(dir, &["cat-file", "-e", &commit]) {
                Ok(_) => Ok(self.base.to_owned()),
                Err(_) => Err(match from_remote {
                    Err(e) => format!("the base commit could not be fetched: {e}"),
                    Ok(_) => "the remote does not have the snapshot's base commit".to_owned(),
                }),
            };
        }
        let file = scratch.join("bundle");
        std::fs::write(&file, self.bundle).map_err(|e| format!("write the bundle: {e}"))?;
        let file = file.to_string_lossy();
        let heads = git(dir, &["bundle", "list-heads", &file])
            .map_err(|e| format!("the snapshot's bundle is not one: {e}"))?;
        let mut first = heads.lines().next().unwrap_or("").split_whitespace();
        let (Some(head), Some(name)) = (first.next(), first.next()) else {
            return Err("the snapshot's bundle has no head".to_owned());
        };
        git(dir, &["fetch", "-q", "--no-tags", &file, name])
            .map_err(|e| format!("the snapshot's commits could not be read: {e}"))?;
        Ok(head.to_owned())
    }
}

/// What a folder that was here held before the snapshot went in.
struct Before {
    /// Its `HEAD`: a branch's short name, or a commit when detached.
    head: String,
    /// Its uncommitted tracked changes as a stash commit; none when it was clean.
    changes: Option<String>,
}

impl Before {
    /// Reads the folder's state and keeps it under `refs/cmux/auto/before/<label>`.
    fn keep(dir: &Path, label: &str) -> Result<Before, String> {
        let commit = git(dir, &["rev-parse", "HEAD"])
            .map_err(|e| format!("the chat's folder is not a git folder with a commit: {e}"))?;
        let branch = git(dir, &["symbolic-ref", "-q", "--short", "HEAD"]).ok();
        let head = branch.filter(|name| !name.is_empty()).unwrap_or_else(|| commit.clone());
        // A stash commit needs an author; a folder whose git has none configured still gets one.
        let me = ["-c", "user.name=cmux", "-c", "user.email=auto@cmux.invalid"];
        let stash = git(dir, &[&me[..], &["stash", "create", "before the Cloud's copy"]].concat())?;
        let changes = Some(stash).filter(|id| !id.is_empty());
        let label: String =
            label.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
        let kept = format!("refs/cmux/auto/before/{label}");
        git(dir, &["update-ref", &kept, changes.as_deref().unwrap_or(&commit)])?;
        Ok(Before { head, changes })
    }

    /// Puts the folder back as it was. Best effort: the ref from [`Self::keep`] holds it either
    /// way.
    fn as_it_was(&self, dir: &Path) {
        let _ = git(dir, &["checkout", "-q", "-f", &self.head]);
        if let Some(changes) = &self.changes {
            let _ = git(dir, &["stash", "apply", "-q", changes]);
        }
    }
}
