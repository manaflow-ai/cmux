//! A chat's repository from a warm mirror on this machine: AutoCloud start's fast clone.
//!
//! A chat started in the Cloud used to get its folder with a full `git clone` of the remote,
//! every history object from GitHub on every start (the cmux repository: about 591 MB, minutes).
//! The Mac's own start already carries its objects (`link seed push`, git-seed-carry-v1); a
//! start that begins in the Cloud has no Mac to carry from, so the machine keeps the sender's
//! half itself:
//!
//! - **The mirror.** One bare, blobless (`--filter=blob:none`) clone per remote, under
//!   `<chats root>/.cmux-git-mirrors/<sha256(remote)[..16]>.git`. The first start makes it
//!   (commits and trees only), every later start fetches what is new into it: a few KB.
//! - **The commit's files.** The blobs of the commit the chat starts at are fetched into the
//!   mirror in one batch (git's own promisor fetch), so the next chat at that commit fetches
//!   none.
//! - **The chat's folder.** A new repository that borrows the mirror's objects through
//!   `objects/info/alternates`, so nothing is copied; `origin` is its promisor remote, so an
//!   old file a command asks for later still comes, by itself, from the remote. Commits made
//!   in the chat are the chat's own objects.
//!
//! The mirror never prunes (`gc.auto 0`, `gc.pruneExpire never`): chats borrow its objects.
//! Anything that fails here leaves the start to the full clone it always had, and
//! `CMUX_AUTO_MIRROR=off` turns the mirror off.

use std::path::{Path, PathBuf};

use sha2::{Digest as _, Sha256};

use super::folder::{git, git_input};
use crate::home_fs;

/// The mirrors' folder, beside the chats' own folders.
const MIRRORS: &str = ".cmux-git-mirrors";

/// The mirror is on unless `CMUX_AUTO_MIRROR=off`.
pub(super) fn enabled() -> bool {
    std::env::var("CMUX_AUTO_MIRROR").map_or(true, |v| v != "off")
}

/// What the chat starts at.
pub(super) enum Want<'a> {
    /// A branch of the remote; its default branch's head when it has none of that name.
    Branch(&'a str),
    /// A commit the remote has.
    Commit(&'a str),
}

/// The chat's repository at `dir`, an empty folder, made from the warm mirror of `remote`:
/// `origin` set, the mirror's objects borrowed, the wanted commit's files in the mirror.
/// Answers the commit, and the branch it is the head of when the remote has that branch.
/// Nothing is checked out.
pub(super) fn attach(
    dir: &Path,
    remote: &str,
    want: Want<'_>,
) -> Result<(String, Option<String>), String> {
    let root = dir.parent().ok_or("the chat's folder has no parent")?.join(MIRRORS);
    let mirror = warm(&root, remote)?;
    let (commit, branch) = match want {
        Want::Branch(branch) => match head_of(&mirror, &format!("refs/heads/{branch}")) {
            Some(commit) => (commit, Some(branch.to_owned())),
            None => (head_of(&mirror, "HEAD").ok_or("the remote has no default branch")?, None),
        },
        Want::Commit(commit) => {
            if head_of(&mirror, commit).is_none() {
                git(
                    &mirror,
                    &["fetch", "-q", "--no-tags", "--filter=blob:none", "origin", commit],
                )?;
            }
            (head_of(&mirror, commit).ok_or("the remote does not have the commit")?, None)
        }
    };
    fill(&mirror, &commit)?;
    if !dir.join(".git").is_dir() {
        git(dir, &["init", "-q"])?;
        git(dir, &["remote", "add", "origin", remote])?;
    }
    let objects = mirror.join("objects");
    let alternates = dir.join(".git/objects/info/alternates");
    home_fs::create_dirs(dir.join(".git/objects/info"))
        .map_err(|e| format!("objects/info: {e}"))?;
    home_fs::write(&alternates, format!("{}\n", objects.display()))
        .map_err(|e| format!("write {}: {e}", alternates.display()))?;
    // A partial clone of `origin`, with no filter of its own: what the chat fetches later comes
    // whole, an old blob it never had comes on demand.
    git(dir, &["config", "core.repositoryformatversion", "1"])?;
    git(dir, &["config", "extensions.partialClone", "origin"])?;
    git(dir, &["config", "remote.origin.promisor", "true"])?;
    track(dir, &mirror)?;
    Ok((commit, branch))
}

/// The mirror of `remote` under `root`, made or brought up to date. Its path is absolute:
/// alternates take no relative path from a folder elsewhere.
fn warm(root: &Path, remote: &str) -> Result<PathBuf, String> {
    home_fs::create_dirs(root).map_err(|e| format!("create {}: {e}", root.display()))?;
    let root = root.canonicalize().map_err(|e| format!("{}: {e}", root.display()))?;
    let key: String =
        Sha256::digest(remote.as_bytes())[..8].iter().map(|b| format!("{b:02x}")).collect();
    let mirror = root.join(format!("{key}.git"));
    if mirror.join("HEAD").is_file() {
        git(&mirror, &["fetch", "-q", "--no-tags", "--filter=blob:none", "origin"])?;
        return Ok(mirror);
    }
    // Made aside and renamed in: a start that sees the mirror sees a whole one. Two first
    // starts both make one; the second's rename finds the first's and its own is dropped.
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    let tmp = root.join(format!(".tmp-{key}-{}-{nanos}", std::process::id()));
    let made = (|| {
        let path = tmp.to_string_lossy();
        git(&root, &["clone", "-q", "--bare", "--filter=blob:none", "--", remote, &path])?;
        git(&tmp, &["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"])?;
        git(&tmp, &["config", "gc.auto", "0"])?;
        git(&tmp, &["config", "gc.pruneExpire", "never"])?;
        home_fs::rename(&tmp, &mirror).map_err(|e| format!("rename the mirror in: {e}"))
    })();
    match made {
        Ok(()) => Ok(mirror),
        Err(_) if mirror.join("HEAD").is_file() => {
            let _ = home_fs::remove_dir_all(&tmp);
            Ok(mirror)
        }
        Err(e) => {
            let _ = home_fs::remove_dir_all(&tmp);
            Err(e)
        }
    }
}

/// The commit `name` names in `repo`, if it has one.
fn head_of(repo: &Path, name: &str) -> Option<String> {
    git(repo, &["rev-parse", "-q", "--verify", &format!("{name}^{{commit}}")])
        .ok()
        .filter(|id| !id.is_empty())
}

/// The files of `commit` fetched into the mirror, in one batch: the ones it has are skipped.
fn fill(mirror: &Path, commit: &str) -> Result<(), String> {
    let listed = git(mirror, &["rev-list", "--objects", "--missing=print", "--no-walk", commit])?;
    let missing: String = listed
        .lines()
        .filter_map(|line| line.strip_prefix('?'))
        .flat_map(|id| [id, "\n"])
        .collect();
    if missing.is_empty() {
        return Ok(());
    }
    // git's own form for a promisor fetch by object id (`promisor-remote.c`): any id, no
    // negotiation, no FETCH_HEAD.
    git_input(
        mirror,
        missing.as_bytes(),
        &[
            "-c",
            "fetch.negotiationAlgorithm=noop",
            "fetch",
            "-q",
            "--no-tags",
            "--no-write-fetch-head",
            "--recurse-submodules=no",
            "--filter=blob:none",
            "--stdin",
            "origin",
        ],
    )
    .map(|_| ())
}

/// The mirror's branches as the chat's `origin/*`, and `origin/HEAD`, as a clone has them.
fn track(dir: &Path, mirror: &Path) -> Result<(), String> {
    let heads = git(mirror, &["for-each-ref", "--format=%(objectname) %(refname)", "refs/heads/"])?;
    let mut updates = String::new();
    for line in heads.lines() {
        let Some((id, name)) = line.split_once(' ') else { continue };
        let Some(branch) = name.strip_prefix("refs/heads/") else { continue };
        updates.push_str(&format!("update refs/remotes/origin/{branch} {id}\n"));
    }
    git_input(dir, updates.as_bytes(), &["update-ref", "--stdin"])?;
    if let Ok(default) = git(mirror, &["symbolic-ref", "-q", "HEAD"])
        && let Some(branch) = default.strip_prefix("refs/heads/")
    {
        let target = format!("refs/remotes/origin/{branch}");
        let _ = git(dir, &["symbolic-ref", "refs/remotes/origin/HEAD", &target]);
    }
    Ok(())
}
