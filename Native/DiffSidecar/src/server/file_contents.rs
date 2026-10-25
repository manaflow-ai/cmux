//! `fileContents`: one file's two sides in a git-backed diff session, so the
//! viewer can show the file's unchanged lines (Load full files) and preview
//! it (Rich preview). The sides are the ones the session's patch compares
//! (`run_git_patch_with_limit`): unstaged is the index against the work tree,
//! staged is HEAD against the index, a branch is its base commit (the merge
//! base the patch diffed from, recorded when the session opened) against the
//! work tree.
//!
//! Only the session's own capability token may read, and only a path the
//! session's patch names in its file headers. Blobs are read with
//! `git cat-file`, confined like the patch (`session_git.rs`); the work tree is
//! read directly, a symbolic link as its target text as git shows it.

use std::collections::HashSet;
use std::io::{BufRead, BufReader};
use std::path::{Component, Path, PathBuf};
use std::process::Stdio;

use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;

use super::{
    AppState, SESSION_GIT_TIMEOUT, SessionGit, SessionOpenError, SessionOwner, git_merge_base,
    has_session_token, session_owner_path, valid_token,
};
use crate::protocol::{
    DiffSource, FileContentsEncoding, FileContentsRequest, FileContentsResult, FileSide,
};

/// The most bytes one side may have; a larger file answers `tooLarge`.
pub(super) const MAX_FILE_SIDE_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum FileContentsError {
    /// Not this token's session, not a git session, or a path the session's
    /// patch does not name.
    Unauthorized,
    Failed,
}

/// What a git-backed session compares, saved in its owner file.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct SessionSides {
    /// The canonical repository root.
    pub(super) repo: String,
    pub(super) kind: SidesKind,
    /// A branch session's base: the commit its patch diffed from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) base_commit: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) enum SidesKind {
    Unstaged,
    Staged,
    Branch,
}

/// Where one side of a file is read from.
#[derive(Clone, Debug, Eq, PartialEq)]
enum SideSource {
    Index,
    Commit(String),
    WorkTree,
}

impl SessionSides {
    fn old_side(&self) -> SideSource {
        match self.kind {
            SidesKind::Unstaged => SideSource::Index,
            SidesKind::Staged => SideSource::Commit("HEAD".to_owned()),
            SidesKind::Branch => SideSource::Commit(self.base_commit.clone().unwrap_or_default()),
        }
    }

    fn new_side(&self) -> SideSource {
        match self.kind {
            SidesKind::Unstaged | SidesKind::Branch => SideSource::WorkTree,
            SidesKind::Staged => SideSource::Index,
        }
    }
}

/// The sides of a session about to be published, from its resolved source.
pub(super) async fn session_sides(
    source: &DiffSource,
    repo: &Path,
    git: &SessionGit,
) -> Result<SessionSides, SessionOpenError> {
    let repo = repo.to_string_lossy().into_owned();
    match source {
        DiffSource::Unstaged { .. } => Ok(SessionSides {
            repo,
            kind: SidesKind::Unstaged,
            base_commit: None,
        }),
        DiffSource::Staged { .. } => Ok(SessionSides {
            repo,
            kind: SidesKind::Staged,
            base_commit: None,
        }),
        DiffSource::Branch {
            base_ref: Some(base_ref),
            ..
        } => Ok(SessionSides {
            repo,
            kind: SidesKind::Branch,
            base_commit: Some(git_merge_base(git, base_ref).await?),
        }),
        DiffSource::Branch { base_ref: None, .. } | DiffSource::Patch { .. } => {
            Err(SessionOpenError::Failed)
        }
    }
}

/// Saves `sides` in the session's owner file (written whole, then renamed).
pub(super) fn record_session_sides(
    root: &Path,
    session_id: &str,
    token: &str,
    sides: SessionSides,
) -> Result<(), String> {
    let path = session_owner_path(root, session_id);
    let owner = SessionOwner {
        session_id: session_id.to_owned(),
        capability_token: token.to_owned(),
        sides: Some(sides),
    };
    let bytes = serde_json::to_vec(&owner).map_err(|error| error.to_string())?;
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, bytes).map_err(|error| error.to_string())?;
    std::fs::rename(&temporary, &path).map_err(|error| {
        let _ = std::fs::remove_file(&temporary);
        error.to_string()
    })
}

/// Answers `fileContents`.
pub(super) async fn read(
    state: &AppState,
    params: &FileContentsRequest,
) -> Result<FileContentsResult, FileContentsError> {
    let sides = authorized_sides(state, params).await?;
    let repo = PathBuf::from(&sides.repo);
    let git = SessionGit::open(&repo, SESSION_GIT_TIMEOUT)
        .await
        .ok_or(FileContentsError::Failed)?;
    let old_path = params.previous_path.as_deref().unwrap_or(&params.path);
    let old = read_side(&git, &repo, &sides.old_side(), old_path).await?;
    let new = read_side(&git, &repo, &sides.new_side(), &params.path).await?;
    let encoding = params.encoding.unwrap_or_default();
    Ok(answer(old, new, encoding))
}

/// One side as read: missing, over the limit, or its bytes.
#[derive(Debug, Eq, PartialEq)]
pub(super) enum Side {
    Missing,
    TooLarge,
    Bytes(Vec<u8>),
}

pub(super) fn answer(old: Side, new: Side, encoding: FileContentsEncoding) -> FileContentsResult {
    if old == Side::TooLarge || new == Side::TooLarge {
        return FileContentsResult {
            too_large: Some(true),
            ..FileContentsResult::default()
        };
    }
    let side = |side: Side| match side {
        Side::Bytes(bytes) => Some(FileSide {
            contents: match encoding {
                FileContentsEncoding::Text => String::from_utf8_lossy(&bytes).into_owned(),
                FileContentsEncoding::Base64 => base64(&bytes),
            },
            encoding,
        }),
        Side::Missing | Side::TooLarge => None,
    };
    FileContentsResult {
        old: side(old),
        new: side(new),
        too_large: None,
    }
}

/// The session's sides, once the token owns the session and the patch names
/// every path asked for.
async fn authorized_sides(
    state: &AppState,
    params: &FileContentsRequest,
) -> Result<SessionSides, FileContentsError> {
    if !valid_token(&params.capability_token)
        || uuid::Uuid::parse_str(&params.session_id).is_err()
        || !safe_relative_path(&params.path)
        || params
            .previous_path
            .as_deref()
            .is_some_and(|path| !safe_relative_path(path))
        || !has_session_token(state, &params.capability_token).await
    {
        return Err(FileContentsError::Unauthorized);
    }
    let root = &state.config.root;
    let bytes = tokio::fs::read(session_owner_path(root, &params.session_id))
        .await
        .map_err(|_| FileContentsError::Unauthorized)?;
    let owner: SessionOwner =
        serde_json::from_slice(&bytes).map_err(|_| FileContentsError::Unauthorized)?;
    if owner.session_id != params.session_id || owner.capability_token != params.capability_token {
        return Err(FileContentsError::Unauthorized);
    }
    let sides = owner.sides.ok_or(FileContentsError::Unauthorized)?;
    let patch = root.join(format!("diff-session-{}.patch", params.session_id));
    let wanted: Vec<String> = std::iter::once(params.path.clone())
        .chain(params.previous_path.clone())
        .collect();
    let named = tokio::task::spawn_blocking(move || patch_names_all(&patch, &wanted))
        .await
        .map_err(|_| FileContentsError::Failed)?;
    if !named {
        return Err(FileContentsError::Unauthorized);
    }
    Ok(sides)
}

/// A repository-relative path with no root, `.` or `..` part and no NUL.
pub(super) fn safe_relative_path(path: &str) -> bool {
    !path.is_empty()
        && !path.contains('\0')
        && Path::new(path)
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

/// Whether the patch at `patch` names every path of `wanted` in a file
/// header (`diff --git`, `---`, `+++`, rename or copy lines). Hunk bodies are
/// not read as headers, so a changed line that looks like one names nothing.
pub(super) fn patch_names_all(patch: &Path, wanted: &[String]) -> bool {
    let Ok(file) = std::fs::File::open(patch) else {
        return false;
    };
    let mut missing: HashSet<&str> = wanted.iter().map(String::as_str).collect();
    let mut reader = BufReader::new(file);
    let mut line = Vec::new();
    let mut in_header = false;
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => return missing.is_empty(),
            Ok(_) => {}
        }
        let text = String::from_utf8_lossy(&line);
        let text = text.trim_end_matches(['\n', '\r']);
        if let Some(rest) = text.strip_prefix("diff --git ") {
            in_header = true;
            for name in diff_git_names(rest) {
                missing.remove(name.as_str());
            }
        } else if in_header {
            if text.starts_with("@@") || text.starts_with("GIT binary patch") {
                in_header = false;
                continue;
            }
            let named = ["--- a/", "+++ b/"]
                .iter()
                .find_map(|prefix| text.strip_prefix(prefix).map(unquote))
                .or_else(|| {
                    ["--- ", "+++ "]
                        .iter()
                        .find_map(|prefix| text.strip_prefix(prefix))
                        .filter(|rest| rest.starts_with('"'))
                        .map(|rest| {
                            let name = unquote(rest);
                            name.strip_prefix("a/")
                                .or_else(|| name.strip_prefix("b/"))
                                .map_or(name.clone(), str::to_owned)
                        })
                })
                .or_else(|| {
                    ["rename from ", "rename to ", "copy from ", "copy to "]
                        .iter()
                        .find_map(|prefix| text.strip_prefix(prefix).map(unquote))
                });
            if let Some(name) = named {
                missing.remove(name.as_str());
            }
        }
        if missing.is_empty() {
            return true;
        }
    }
}

/// The two names of a `diff --git a/<old> b/<new>` line, when they can be
/// split: quoted names, or two equal unquoted names (a space in a name makes
/// the split ambiguous otherwise, and the `---` and `+++` lines name it).
pub(super) fn diff_git_names(rest: &str) -> Vec<String> {
    if rest.starts_with('"') {
        let mut names = Vec::new();
        let mut remaining = rest;
        while let Some(end) = quoted_end(remaining) {
            names.push(unquote(&remaining[..=end]));
            remaining = remaining[end + 1..].trim_start();
            if !remaining.starts_with('"') {
                if let Some(plain) = remaining.strip_prefix("b/") {
                    names.push(format!("b/{plain}"));
                }
                break;
            }
        }
        return names
            .into_iter()
            .filter_map(|name| {
                name.strip_prefix("a/")
                    .or_else(|| name.strip_prefix("b/"))
                    .map(str::to_owned)
            })
            .collect();
    }
    let Some(rest) = rest.strip_prefix("a/") else {
        return Vec::new();
    };
    // `<name> b/<name>`: the length gives the split.
    if rest.len() >= 3 && (rest.len() - 3) % 2 == 0 {
        let length = (rest.len() - 3) / 2;
        if rest.is_char_boundary(length)
            && rest.is_char_boundary(length + 3)
            && &rest[length..length + 3] == " b/"
            && rest[..length] == rest[length + 3..]
        {
            return vec![rest[..length].to_owned()];
        }
    }
    Vec::new()
}

/// The index of the closing quote of the C-quoted name `text` starts with.
fn quoted_end(text: &str) -> Option<usize> {
    let bytes = text.as_bytes();
    if bytes.first() != Some(&b'"') {
        return None;
    }
    let mut index = 1;
    while index < bytes.len() {
        match bytes[index] {
            b'\\' => index += 2,
            b'"' => return Some(index),
            _ => index += 1,
        }
    }
    None
}

/// Git's C-quoted path (`"a/sp\303\251cial \"x\""`) as its text; any other
/// text as it is.
pub(super) fn unquote(text: &str) -> String {
    let Some(inner) = text
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
    else {
        return text.to_owned();
    };
    let mut bytes = Vec::with_capacity(inner.len());
    let mut chars = inner.bytes().peekable();
    while let Some(byte) = chars.next() {
        if byte != b'\\' {
            bytes.push(byte);
            continue;
        }
        match chars.next() {
            Some(b'n') => bytes.push(b'\n'),
            Some(b't') => bytes.push(b'\t'),
            Some(b'r') => bytes.push(b'\r'),
            Some(b'a') => bytes.push(0x07),
            Some(b'b') => bytes.push(0x08),
            Some(b'f') => bytes.push(0x0c),
            Some(b'v') => bytes.push(0x0b),
            Some(digit @ b'0'..=b'7') => {
                let mut value = u32::from(digit - b'0');
                for _ in 0..2 {
                    match chars.peek() {
                        Some(next @ b'0'..=b'7') => {
                            value = value * 8 + u32::from(next - b'0');
                            chars.next();
                        }
                        _ => break,
                    }
                }
                bytes.push(u8::try_from(value & 0xff).unwrap_or(0));
            }
            Some(other) => bytes.push(other),
            None => bytes.push(b'\\'),
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

async fn read_side(
    git: &SessionGit,
    repo: &Path,
    source: &SideSource,
    path: &str,
) -> Result<Side, FileContentsError> {
    match source {
        SideSource::Index => read_blob(git, &format!(":0:{path}")).await,
        SideSource::Commit(commit) if commit.is_empty() => Err(FileContentsError::Failed),
        SideSource::Commit(commit) => read_blob(git, &format!("{commit}:{path}")).await,
        SideSource::WorkTree => read_work_tree(repo, path).await,
    }
}

/// A blob by its `<rev>:<path>` spec: missing when git has no such object.
async fn read_blob(git: &SessionGit, spec: &str) -> Result<Side, FileContentsError> {
    let mut size = git.command();
    size.args(["cat-file", "-s", "--end-of-options", spec])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(SESSION_GIT_TIMEOUT, size.output())
        .await
        .map_err(|_| FileContentsError::Failed)?
        .map_err(|_| FileContentsError::Failed)?;
    if !output.status.success() {
        // No such path at that revision (an added file's old side, a path
        // not in the index) or no such revision (HEAD before the first
        // commit): this side does not exist.
        return Ok(Side::Missing);
    }
    let length: u64 = String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse()
        .map_err(|_| FileContentsError::Failed)?;
    if length > MAX_FILE_SIDE_BYTES {
        return Ok(Side::TooLarge);
    }
    let mut blob = git.command();
    blob.args(["cat-file", "blob", "--end-of-options", spec])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = blob.spawn().map_err(|_| FileContentsError::Failed)?;
    let mut stdout = child.stdout.take().ok_or(FileContentsError::Failed)?;
    let read = tokio::time::timeout(SESSION_GIT_TIMEOUT, async {
        let mut bytes = Vec::new();
        (&mut stdout)
            .take(MAX_FILE_SIDE_BYTES + 1)
            .read_to_end(&mut bytes)
            .await
            .ok()?;
        let status = child.wait().await.ok()?;
        status.success().then_some(bytes)
    })
    .await
    .ok()
    .flatten()
    .ok_or(FileContentsError::Failed)?;
    if read.len() as u64 > MAX_FILE_SIDE_BYTES {
        return Ok(Side::TooLarge);
    }
    Ok(Side::Bytes(read))
}

/// The work tree's side: a regular file's bytes, a symbolic link's target
/// text (as git diffs it), missing when there is no file there (deleted, or a
/// folder such as a submodule).
async fn read_work_tree(repo: &Path, path: &str) -> Result<Side, FileContentsError> {
    let full = repo.join(path);
    // Every folder on the way must be a real folder inside the repository: a
    // linked folder could reach outside it.
    let mut folder = repo.to_path_buf();
    for component in Path::new(path)
        .parent()
        .into_iter()
        .flat_map(Path::components)
    {
        folder.push(component);
        match tokio::fs::symlink_metadata(&folder).await {
            Ok(metadata) if metadata.is_dir() => {}
            Ok(_) => return Err(FileContentsError::Unauthorized),
            Err(_) => return Ok(Side::Missing),
        }
    }
    let Ok(metadata) = tokio::fs::symlink_metadata(&full).await else {
        return Ok(Side::Missing);
    };
    if metadata.file_type().is_symlink() {
        let target = tokio::fs::read_link(&full)
            .await
            .map_err(|_| FileContentsError::Failed)?;
        return Ok(Side::Bytes(target.as_os_str().as_encoded_bytes().to_vec()));
    }
    if !metadata.is_file() {
        return Ok(Side::Missing);
    }
    if metadata.len() > MAX_FILE_SIDE_BYTES {
        return Ok(Side::TooLarge);
    }
    let file = tokio::fs::File::open(&full)
        .await
        .map_err(|_| FileContentsError::Failed)?;
    let mut bytes = Vec::new();
    file.take(MAX_FILE_SIDE_BYTES + 1)
        .read_to_end(&mut bytes)
        .await
        .map_err(|_| FileContentsError::Failed)?;
    if bytes.len() as u64 > MAX_FILE_SIDE_BYTES {
        return Ok(Side::TooLarge);
    }
    Ok(Side::Bytes(bytes))
}

/// Standard base64 with padding (RFC 4648), for a binary side.
pub(super) fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let triple = (u32::from(chunk[0]) << 16)
            | (u32::from(chunk.get(1).copied().unwrap_or(0)) << 8)
            | u32::from(chunk.get(2).copied().unwrap_or(0));
        let digit = |shift: u32| char::from(ALPHABET[((triple >> shift) & 0x3f) as usize]);
        text.push(digit(18));
        text.push(digit(12));
        text.push(if chunk.len() > 1 { digit(6) } else { '=' });
        text.push(if chunk.len() > 2 { digit(0) } else { '=' });
    }
    text
}
