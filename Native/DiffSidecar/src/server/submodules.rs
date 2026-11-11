//! Superrepo diffs (CMUX-5): a git session in a repository with submodules
//! also shows the files that changed inside each checked-out submodule, as
//! paths under the submodule's folder (`sub/file.txt`), after the
//! superproject's own `Subproject commit` lines.
//!
//! Each submodule is diffed by its own confined git (`SessionGit`, so its
//! filter drivers are blanked too), never by `diff.submodule=diff`, which
//! would run the submodule's own diff drivers. The superproject's raw diff
//! names each changed gitlink and the commit it had on the old side; the
//! submodule then diffs from that commit to its work tree (unstaged and
//! branch sessions) or to the new gitlink commit (staged sessions). Nested
//! submodules follow the same way, a few levels deep.
//!
//! Best effort, like untracked files: a submodule that is not checked out,
//! lacks the old commit, fails, times out or does not fit the remaining
//! budget is left out, and its `Subproject commit` lines still show.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

use super::file_contents::safe_relative_path;
use super::{
    MAX_UNTRACKED_FILE_PATCH_BYTES, SESSION_GIT_TIMEOUT, SessionOpenError, Whitespace,
    git_single_line, git_untracked_file_patch, git_untracked_paths,
};
use crate::session_git::SessionGit;

/// The most submodules one session diffs, at every depth together.
const MAX_SUBMODULES: usize = 64;
/// The deepest nested submodule a session diffs (1 is a direct submodule).
const MAX_DEPTH: usize = 4;
/// The most one submodule's patch may add to the session patch.
const MAX_SUBMODULE_PATCH_BYTES: u64 = 64 * 1024 * 1024;
/// The most bytes a raw gitlink listing may take.
const MAX_RAW_LISTING_BYTES: usize = 4 * 1024 * 1024;
/// git's empty tree, the old side of a newly added submodule.
const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// The new side of a superproject diff.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum NewSide {
    /// The work tree (unstaged and branch sessions).
    WorkTree,
    /// Committed content (staged sessions): each gitlink's new commit.
    Commits,
}

/// One gitlink the superproject's diff changed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct ChangedSubmodule {
    /// Its folder, relative to the repository that records it.
    pub path: String,
    /// The commit the old side recorded, or `None` for a new submodule.
    pub old: Option<String>,
    /// The commit the new side records, for [`NewSide::Commits`].
    pub new: Option<String>,
}

/// The gitlinks in `git diff --raw -z --no-abbrev --no-renames` output that
/// still are a submodule on the new side. A removed submodule keeps only its
/// `Subproject commit` lines: there is no work tree to diff.
pub(super) fn changed_submodules(raw: &[u8]) -> Vec<ChangedSubmodule> {
    let mut found = Vec::new();
    let mut fields = raw.split(|byte| *byte == 0);
    while let Some(header) = fields.next() {
        if header.is_empty() {
            continue;
        }
        let Some(path) = fields.next() else { break };
        let Ok(header) = std::str::from_utf8(header) else {
            continue;
        };
        let Ok(path) = std::str::from_utf8(path) else {
            continue;
        };
        let parts: Vec<&str> = header.trim_start_matches(':').split(' ').collect();
        let [old_mode, new_mode, old_sha, new_sha, _status] = parts.as_slice() else {
            continue;
        };
        if *new_mode != "160000" || !safe_relative_path(path) {
            continue;
        }
        let old = (*old_mode == "160000" && is_object_id(old_sha) && !is_zero(old_sha))
            .then(|| (*old_sha).to_owned());
        let new = (is_object_id(new_sha) && !is_zero(new_sha)).then(|| (*new_sha).to_owned());
        found.push(ChangedSubmodule {
            path: path.to_owned(),
            old,
            new,
        });
    }
    found
}

fn is_object_id(value: &str) -> bool {
    matches!(value.len(), 40 | 64) && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn is_zero(value: &str) -> bool {
    value.bytes().all(|byte| byte == b'0')
}

/// A submodule a session's patch diffed, saved with the session's sides so
/// Load full files reads its files from the submodule's own git.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DiffedSubmodule {
    /// Its folder inside the session's repository, with a trailing `/`.
    pub prefix: String,
    /// The commit (or the empty tree) its old side is read from.
    pub old: String,
    /// The commit its new side is read from, or `None` for its work tree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new: Option<String>,
}

/// One repository level to look for changed submodules in.
struct Level {
    git: SessionGit,
    folder: PathBuf,
    /// The path of `folder` inside the session's repository, with a
    /// trailing `/`, or empty for the repository itself.
    prefix: String,
    /// The revisions its diff compares (`--cached`, a commit, two commits).
    revisions: Vec<String>,
    depth: usize,
}

/// What every level of one session shares.
pub(super) struct Session<'a> {
    pub whitespace: Whitespace,
    pub new_side: NewSide,
    /// Whether untracked files of each submodule are added (unstaged
    /// sessions, as for the repository itself).
    pub untracked: bool,
    pub output: &'a mut tokio::fs::File,
    pub bytes_written: &'a mut u64,
    pub max_patch_bytes: u64,
}

/// Appends the patch of each changed submodule of `repo` (and theirs, a few
/// levels deep) to the session patch. `revisions` are the arguments the
/// repository's own diff compared (`--cached`, or a merge base). Returns the
/// submodules it diffed.
pub(super) async fn append_submodule_patches(
    git: SessionGit,
    repo: &Path,
    revisions: Vec<String>,
    session: Session<'_>,
) -> Result<Vec<DiffedSubmodule>, SessionOpenError> {
    let Session {
        whitespace,
        new_side,
        untracked,
        output,
        bytes_written,
        max_patch_bytes,
    } = session;
    let mut pending = vec![Level {
        git,
        folder: repo.to_path_buf(),
        prefix: String::new(),
        revisions,
        depth: 0,
    }];
    let mut diffed = Vec::new();
    while let Some(level) = pending.pop() {
        if level.depth >= MAX_DEPTH {
            continue;
        }
        let Some(raw) = raw_gitlinks(&level).await else {
            continue;
        };
        for submodule in changed_submodules(&raw) {
            if diffed.len() >= MAX_SUBMODULES {
                return Ok(diffed);
            }
            let new = match new_side {
                NewSide::WorkTree => None,
                NewSide::Commits => match submodule.new.clone() {
                    Some(new) => Some(new),
                    None => continue,
                },
            };
            let Some(git) = open_submodule(&level.folder, &submodule.path).await else {
                continue;
            };
            let folder = level.folder.join(&submodule.path);
            let prefix = format!("{}{}/", level.prefix, submodule.path);
            let old = submodule.old.unwrap_or_else(|| EMPTY_TREE.to_owned());
            diffed.push(DiffedSubmodule {
                prefix: prefix.clone(),
                old: old.clone(),
                new: new.clone(),
            });
            let mut revisions = vec![old];
            revisions.extend(new);

            let budget = max_patch_bytes
                .saturating_sub(*bytes_written)
                .min(MAX_SUBMODULE_PATCH_BYTES);
            let mut command = git.command();
            command.args(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--binary"]);
            command.args(whitespace.diff_args());
            command.args(prefix_args(&prefix));
            command.args(&revisions);
            command.arg("--");
            if let Some(patch) = collect_stdout(command, budget, &[0]).await {
                write(output, bytes_written, &patch).await?;
            }
            if untracked {
                append_untracked(&git, &prefix, output, bytes_written, max_patch_bytes).await?;
            }
            pending.push(Level {
                git,
                folder,
                prefix,
                revisions,
                depth: level.depth + 1,
            });
        }
    }
    Ok(diffed)
}

/// The submodule of `submodules` that holds `path` (the deepest, for a
/// nested one), and `path` inside it.
pub(super) fn containing<'a>(
    submodules: &'a [DiffedSubmodule],
    path: &'a str,
) -> Option<(&'a DiffedSubmodule, &'a str)> {
    submodules
        .iter()
        .filter_map(|submodule| {
            path.strip_prefix(submodule.prefix.as_str())
                .filter(|inner| !inner.is_empty())
                .map(|inner| (submodule, inner))
        })
        .max_by_key(|(submodule, _)| submodule.prefix.len())
}

/// The confined git of the diffed submodule at `prefix` inside `repo`.
pub(super) async fn open_diffed(repo: &Path, prefix: &str) -> Option<SessionGit> {
    open_submodule(repo, prefix.trim_end_matches('/')).await
}

/// `--src-prefix` and `--dst-prefix` that put a submodule's paths under its
/// folder, the way the superproject would name them.
pub(super) fn prefix_args(prefix: &str) -> [String; 2] {
    [
        format!("--src-prefix=a/{prefix}"),
        format!("--dst-prefix=b/{prefix}"),
    ]
}

async fn raw_gitlinks(level: &Level) -> Option<Vec<u8>> {
    let mut command = level.git.command();
    command.args(["diff", "--raw", "-z", "--no-abbrev", "--no-renames"]);
    command.args(&level.revisions);
    command.arg("--");
    collect_stdout(command, MAX_RAW_LISTING_BYTES as u64, &[0]).await
}

/// The confined git of the submodule checked out at `path` inside `folder`,
/// or `None` when it is not checked out there. Every folder on the way must
/// be a real folder (a linked one could reach outside the repository), and
/// the submodule must be the top of its own work tree: an empty folder of a
/// submodule that was never checked out would otherwise run git in the
/// superproject.
async fn open_submodule(folder: &Path, path: &str) -> Option<SessionGit> {
    let mut current = folder.to_path_buf();
    for component in Path::new(path).components() {
        current.push(component);
        let metadata = tokio::fs::symlink_metadata(&current).await.ok()?;
        if !metadata.is_dir() {
            return None;
        }
    }
    tokio::fs::symlink_metadata(current.join(".git")).await.ok()?;
    let git = SessionGit::open(&current, SESSION_GIT_TIMEOUT).await?;
    let top = git_single_line(&git, &["rev-parse", "--show-toplevel"]).await.ok()?;
    let top = tokio::fs::canonicalize(top).await.ok()?;
    let expected = tokio::fs::canonicalize(&current).await.ok()?;
    (top == expected).then_some(git)
}

async fn append_untracked(
    git: &SessionGit,
    prefix: &str,
    output: &mut tokio::fs::File,
    bytes_written: &mut u64,
    max_patch_bytes: u64,
) -> Result<(), SessionOpenError> {
    let paths = git_untracked_paths(git).await.unwrap_or_default();
    for path in paths {
        let budget = max_patch_bytes
            .saturating_sub(*bytes_written)
            .min(MAX_UNTRACKED_FILE_PATCH_BYTES);
        let Some(patch) = git_untracked_file_patch(git, path, budget, prefix).await else {
            continue;
        };
        write(output, bytes_written, &patch).await?;
    }
    Ok(())
}

async fn write(
    output: &mut tokio::fs::File,
    bytes_written: &mut u64,
    patch: &[u8],
) -> Result<(), SessionOpenError> {
    output
        .write_all(patch)
        .await
        .map_err(|_| SessionOpenError::Failed)?;
    *bytes_written += patch.len() as u64;
    Ok(())
}

/// One git command's stdout, or `None` when it fails, times out, exits with
/// a code outside `allowed_exit_codes` or prints more than `budget` bytes.
/// Output is buffered so a rejected run leaves nothing in the session patch.
pub(super) async fn collect_stdout(
    mut command: Command,
    budget: u64,
    allowed_exit_codes: &[i32],
) -> Option<Vec<u8>> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().ok()?;
    let mut stdout = child.stdout.take()?;
    let collected = tokio::time::timeout(SESSION_GIT_TIMEOUT, async {
        let mut collected_bytes = Vec::new();
        let mut buffer = vec![0_u8; 64 * 1024];
        loop {
            let read = stdout.read(&mut buffer).await.ok()?;
            if read == 0 {
                break;
            }
            if (collected_bytes.len() + read) as u64 > budget {
                return None;
            }
            collected_bytes.extend_from_slice(&buffer[..read]);
        }
        let status = child.wait().await.ok()?;
        status
            .code()
            .is_some_and(|code| allowed_exit_codes.contains(&code))
            .then_some(collected_bytes)
    })
    .await
    .ok()
    .flatten();
    if collected.is_none() {
        let _ = child.kill().await;
        let _ = child.wait().await;
    }
    collected
}

#[cfg(test)]
mod parse_tests {
    use super::{ChangedSubmodule, changed_submodules};

    const OLD: &str = "2621cb2ac24f39ac1617524b3acb58680c20345f";
    const NEW: &str = "f6d5fbba9637f1e61d9a5fd8eb0dd45f91963eb2";
    const ZERO: &str = "0000000000000000000000000000000000000000";

    #[test]
    fn raw_listing_keeps_only_gitlinks_that_remain_submodules() {
        let raw = format!(
            ":160000 160000 {OLD} {NEW} M\0sub\0\
             :100644 100644 {OLD} {NEW} M\0file.txt\0\
             :000000 160000 {ZERO} {NEW} A\0added\0\
             :160000 000000 {OLD} {ZERO} D\0removed\0\
             :160000 160000 {OLD} {NEW} M\0../escape\0"
        );
        assert_eq!(
            changed_submodules(raw.as_bytes()),
            vec![
                ChangedSubmodule {
                    path: "sub".to_owned(),
                    old: Some(OLD.to_owned()),
                    new: Some(NEW.to_owned()),
                },
                ChangedSubmodule {
                    path: "added".to_owned(),
                    old: None,
                    new: Some(NEW.to_owned()),
                },
            ]
        );
    }
}
