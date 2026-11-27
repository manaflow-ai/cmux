//! A snapshot's folder on this machine. Blocking: git and file work, run off the async threads.
//!
//! A git folder is `session_move_carry`'s form: `base`, a commit the remote has; a git bundle of
//! the local commits past it (its first head is the chat's `HEAD`); and one binary patch of the
//! uncommitted work, applied on top.
//!
//! - New here: an empty repository of `remote`, `base` fetched from it, the bundle fetched on
//!   top, `branch` checked out at the bundle's head, the patch applied. A plain folder is its
//!   tar, unpacked.
//! - Already here (a handback into the laptop's own folder): the folder becomes the snapshot's,
//!   at the repository's top. What it held before is not lost: its commit and its uncommitted
//!   tracked changes are kept under `refs/cmux/auto/before/<label>` first, and an untracked
//!   file where the snapshot has a file is set aside (`reconcile.rs`): dropped when it is the
//!   same file, kept when it differs. A patch that does not apply changes nothing. A folder
//!   that is no repository is not handed back over (`PLAIN_BLOCKED`).
//!
//! A new folder is made under a hidden name beside its place and renamed there once whole, so
//! nobody sees it half made; one that cannot be finished is removed.

use std::path::{Path, PathBuf};

use cmux_auto_session::wire::Cwd;
use cmux_process::Command;

use super::{mirror, reconcile};

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
        return place_new(dir, cwd, first, patch, label);
    }
    if !dir.is_dir() {
        return Err(format!("the chat's folder {} is gone", dir.display()));
    }
    match cwd {
        Cwd::Folder { .. } => Err(PLAIN_BLOCKED.to_owned()),
        Cwd::Git { remote, branch, base, .. } => {
            Git { remote, branch, base, bundle: first, patch }.lay_out(dir, false, label)
        }
    }
}

/// A new folder is laid out beside `dir`, in the same parent (the warm mirror is found
/// there), and renamed to `dir` only once it is whole: whoever looks at `dir` (the person's
/// file tree, the harness, a check) sees no folder or the snapshot's whole folder, never a
/// repository with no commit yet while the base is fetched. A folder that cannot be finished
/// is removed, and `dir` was never made.
fn place_new(dir: &Path, cwd: &Cwd, first: &[u8], patch: &[u8], label: &str) -> Result<(), String> {
    let (Some(parent), Some(name)) = (dir.parent(), dir.file_name()) else {
        return Err(format!("the chat's folder {} has no parent", dir.display()));
    };
    if dir.exists() {
        make_empty(dir)?;
    }
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos());
    let partial = parent.join(format!(
        "{}{}.{}-{stamp}",
        ARRIVING,
        name.to_string_lossy(),
        std::process::id()
    ));
    make_empty(&partial)?;
    let placed = match cwd {
        Cwd::Folder { .. } => unpack(&partial, first),
        Cwd::Git { remote, branch, base, .. } => {
            Git { remote, branch, base, bundle: first, patch }.lay_out(&partial, true, label)
        }
    }
    .and_then(|()| {
        // An empty folder in the way (made before this import) gives way; one with files
        // in it is someone's, and stops the import.
        if dir.exists() {
            make_empty(dir)?;
            home_fs::remove_dir(dir).map_err(|e| format!("remove {}: {e}", dir.display()))?;
        }
        home_fs::rename(&partial, dir).map_err(|e| format!("move the folder into place: {e}"))
    });
    if placed.is_err() {
        let _ = home_fs::remove_dir_all(&partial);
    }
    placed
}

/// The name a new folder has while it is laid out: `.arriving-<chat id>.<pid>-<nanos>`.
pub(super) const ARRIVING: &str = ".arriving-";

/// A tar holds the files the Cloud has, not which ones it deleted, so laid over a folder that is
/// here it would bring back what the Cloud removed, and a delete-what-is-absent rule would
/// remove what the laptop made after the copy. Neither is safe, so a folder that is no
/// repository is not handed back over an existing one: it stays as it is (the first release is
/// git folders only).
const PLAIN_BLOCKED: &str = "the chat's folder is not a git repository, so the Cloud's copy \
    cannot be laid over it without bringing back files the Cloud deleted; the folder is left \
    as it is";

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
    let cloned = from_mirror(dir, remote, branch)
        .or_else(|why| {
            if !why.is_empty() {
                tracing::info!(%why, "the warm mirror did not make the chat's folder; cloning");
            }
            let _ = home_fs::remove_dir_all(dir);
            make_empty(dir)?;
            git(dir, &["clone", "-q", "--branch", branch, "--", remote, "."])
        })
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

/// The chat's folder from the warm mirror of `remote` (`mirror.rs`): `branch` checked out,
/// tracking `origin/<branch>`; at the default branch's head when the remote has no `branch`.
/// An empty error: the mirror is off.
fn from_mirror(dir: &Path, remote: &str, branch: &str) -> Result<String, String> {
    if !mirror::enabled() {
        return Err(String::new());
    }
    let (commit, tracked) = mirror::attach(dir, remote, mirror::Want::Branch(branch))?;
    git(dir, &["checkout", "-q", "-b", branch, &commit])?;
    if tracked.is_some() {
        git(dir, &["branch", "-q", &format!("--set-upstream-to=origin/{branch}"), branch])?;
    }
    Ok(commit)
}

/// Git in `dir` for a snapshot's folder. It reaches the remote with the machine's own git
/// credentials, never asks at a terminal, gives up on a stalled transfer, and runs no hook of
/// the repository.
pub(super) fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    git_with(dir, &[], args)
}

/// [`git`] with `input` on its stdin.
pub(super) fn git_input(dir: &Path, input: &[u8], args: &[&str]) -> Result<String, String> {
    run(dir, &[], Some(input), args)
}

/// [`git`] with more environment variables.
pub(super) fn git_with(
    dir: &Path,
    env: &[(&str, String)],
    args: &[&str],
) -> Result<String, String> {
    run(dir, env, None, args)
}

fn run(
    dir: &Path,
    env: &[(&str, String)],
    input: Option<&[u8]>,
    args: &[&str],
) -> Result<String, String> {
    // The input goes in as a file: the child reads it at its own pace, so a full stdout never
    // blocks a writer.
    let scratch = match input {
        Some(input) => {
            let file = tempfile::NamedTempFile::new().map_err(|e| format!("a temp file: {e}"))?;
            std::fs::write(file.path(), input).map_err(|e| format!("write git's input: {e}"))?;
            Some(file)
        }
        None => None,
    };
    let mut command = Command::new("git");
    command
        .envs(env.iter().map(|(k, v)| (*k, v.as_str())))
        .arg("-C")
        .arg(dir)
        .args(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"])
        .args(["-c", "submodule.recurse=false", "-c", "http.lowSpeedLimit=1000"])
        .args(["-c", "http.lowSpeedTime=60"])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_SSH_COMMAND", "ssh -oBatchMode=yes")
        .env("GIT_LFS_SKIP_SMUDGE", "1")
        .env("LC_ALL", "C");
    if let Some(file) = &scratch {
        command.open_stdin_path(file.path());
    }
    let out = command.output().map_err(|e| format!("git did not start: {e}"))?;
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
        let file = scratch.path().join("patch");
        std::fs::write(&file, self.patch).map_err(|e| format!("write the patch: {e}"))?;
        let patch = if self.patch.is_empty() { PathBuf::new() } else { file.clone() };
        // The patch is cut from the repository's top, so it goes on there: a chat that started
        // in a subfolder keeps its own folder as the chat's `cwd`, and git there would skip
        // the files outside it.
        let (root, before) = if fresh {
            git(dir, &["init", "-q"])?;
            git(dir, &["remote", "add", "origin", self.remote])?;
            // The base's objects from the warm mirror, borrowed (`mirror.rs`); the fetch below
            // then finds the base here and asks the remote for nothing.
            if mirror::enabled()
                && let Err(why) = mirror::attach(dir, self.remote, mirror::Want::Commit(self.base))
            {
                tracing::info!(%why, "the warm mirror did not lend the base; fetching it");
            }
            (dir.to_owned(), None)
        } else {
            let top = git(dir, &["rev-parse", "--show-toplevel"])
                .map_err(|e| format!("the chat's folder is not in a git folder: {e}"))?;
            let root = PathBuf::from(top);
            let before = Before::keep(&root, label)?;
            (root, Some(before))
        };
        let head = self.fetch_commits(&root, scratch.path())?;
        // The patch is tried on a scratch index first: one that does not apply changes nothing.
        let tree = reconcile::tree_with(&root, scratch.path(), &head, &patch)?;
        let mut aside = match &before {
            Some(_) => {
                let git_dir = git(&root, &["rev-parse", "--absolute-git-dir"])?;
                Some(reconcile::Aside::make(&root, Path::new(&git_dir), &tree, &safe(label))?)
            }
            None => None,
        };
        let laid = self.check_out(&root, &head, &file);
        match (laid, &mut aside) {
            (Ok(()), Some(_)) => {
                let kept = aside.take().map(reconcile::Aside::done).unwrap_or_default();
                if !kept.is_empty() {
                    tracing::warn!(files = ?kept, "a handback set local files aside that differ from the Cloud's");
                }
                Ok(())
            }
            (Ok(()), None) => Ok(()),
            (Err(error), _) => {
                if let Some(aside) = &mut aside {
                    aside.put_back();
                }
                if let Some(before) = &before {
                    before.as_it_was(&root);
                }
                Err(error)
            }
        }
    }

    /// The commits checked out and the patch applied, at the repository's top.
    fn check_out(&self, root: &Path, head: &str, patch: &Path) -> Result<(), String> {
        let mut checkout = vec!["checkout", "-q"];
        if root.join(".git").exists() && git(root, &["rev-parse", "-q", "--verify", "HEAD"]).is_ok()
        {
            checkout.push("-f");
        }
        match self.branch {
            // A detached checkout: the copy's side names it `HEAD` (`export/folder.rs`).
            "" | "HEAD" => checkout.extend(["--detach", head]),
            branch => checkout.extend(["-B", branch, head]),
        }
        git(root, &checkout)?;
        self.keep_base(root);
        if self.patch.is_empty() {
            return Ok(());
        }
        let file = patch.to_string_lossy();
        git(root, &["apply", "--binary", "--whitespace=nowarn", &file])
            .map(|_| ())
            .map_err(|e| format!("the snapshot's patch does not apply: {e}"))
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
        let base = format!("{}^{{commit}}", self.base);
        let have_base = git(dir, &["cat-file", "-e", &base]).is_ok();
        let from_remote = if have_base {
            Ok(String::new())
        } else {
            git(dir, &["fetch", "-q", "--no-tags", "origin", self.base])
        }
        .or_else(|e| match self.branch {
            "" => Err(e),
            branch => git(dir, &["fetch", "-q", "--no-tags", "origin", branch]),
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

/// A label as one path and ref component.
fn safe(label: &str) -> String {
    label.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
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
        let kept = format!("refs/cmux/auto/before/{}", safe(label));
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
