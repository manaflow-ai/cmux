//! Files git does not track that stand where a snapshot puts a file, on a handback into the
//! laptop's own folder.
//!
//! A forced checkout leaves untracked files alone, and `git apply` refuses to add a file that
//! exists, so a file the laptop carried to the Cloud and still has would block the handback
//! for ever. Before anything is placed, each such file is moved under the repository's
//! `cmux-auto/quarantine/<label>`. One that is the same file as the snapshot's (same content,
//! same exec bit) is dropped once the snapshot has put it back; one that differs stays there
//! for the person, and is listed in the answer. If the snapshot then fails to go in, every
//! file goes back where it was. No file is deleted that the snapshot does not replace.

use std::collections::HashSet;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use super::folder::{git, git_with};

/// What the snapshot's tree holds at one path.
struct Entry {
    mode: String,
    blob: String,
    path: PathBuf,
}

/// A local file moved aside.
pub(super) struct Moved {
    pub path: PathBuf,
    pub same: bool,
    aside: PathBuf,
}

/// The files moved aside for one placement.
pub(super) struct Aside {
    root: PathBuf,
    moved: Vec<Moved>,
}

#[cfg(unix)]
fn path_of(bytes: &[u8]) -> PathBuf {
    use std::os::unix::ffi::OsStrExt as _;
    PathBuf::from(std::ffi::OsStr::from_bytes(bytes))
}

/// Git names paths in UTF-8 on Windows.
#[cfg(not(unix))]
fn path_of(bytes: &[u8]) -> PathBuf {
    PathBuf::from(String::from_utf8_lossy(bytes).into_owned())
}

/// Whether `meta`'s file is executable as git sees it. Windows has no exec bit (git there
/// keeps the tree's), so the tree entry's own bit stands.
#[cfg(unix)]
fn executable(meta: &std::fs::Metadata, _entry: &Entry) -> bool {
    meta.permissions().mode() & 0o111 != 0
}

/// Whether `meta`'s file is executable as git sees it. Windows has no exec bit (git there
/// keeps the tree's), so the tree entry's own bit stands.
#[cfg(not(unix))]
fn executable(_meta: &std::fs::Metadata, entry: &Entry) -> bool {
    entry.mode == "100755"
}

/// The tree of `head` with `patch` applied, in a scratch index: nothing the person sees changes.
/// A patch that does not apply is found here, before any file is touched.
pub(super) fn tree_with(
    root: &Path,
    scratch: &Path,
    head: &str,
    patch: &Path,
) -> Result<String, String> {
    let index = scratch.join("index");
    let env = [("GIT_INDEX_FILE", index.to_string_lossy().into_owned())];
    git_with(root, &env, &["read-tree", head])?;
    if !patch.as_os_str().is_empty() {
        let file = patch.to_string_lossy();
        let args = ["apply", "--cached", "--binary", "--whitespace=nowarn", &file];
        git_with(root, &env, &args)
            .map_err(|e| format!("the snapshot's patch does not apply: {e}"))?;
    }
    git_with(root, &env, &["write-tree"])
}

fn entries(root: &Path, tree: &str) -> Result<Vec<Entry>, String> {
    let raw = git(root, &["ls-tree", "-r", "-z", "--full-tree", tree])?;
    Ok(raw
        .split('\0')
        .filter_map(|record| {
            let (meta, name) = record.split_once('\t')?;
            let mut parts = meta.split_whitespace();
            let mode = parts.next()?.to_owned();
            let _kind = parts.next()?;
            let blob = parts.next()?.to_owned();
            Some(Entry { mode, blob, path: path_of(name.as_bytes()) })
        })
        .collect())
}

fn untracked(root: &Path) -> Result<HashSet<PathBuf>, String> {
    // Ignored files too: a forced checkout overwrites those as well.
    let raw = git(root, &["ls-files", "-z", "--others"])?;
    Ok(raw.split('\0').filter(|name| !name.is_empty()).map(|n| path_of(n.as_bytes())).collect())
}

/// Whether the file at `file` is what the tree entry says.
fn same_as(root: &Path, file: &Path, entry: &Entry) -> bool {
    let Ok(meta) = std::fs::symlink_metadata(file) else { return false };
    if !meta.is_file() {
        return false;
    }
    let exec = executable(&meta, entry);
    if exec != (entry.mode == "100755") || entry.mode == "120000" {
        return false;
    }
    git(root, &["hash-object", "--no-filters", "--", &file.to_string_lossy()])
        .is_ok_and(|id| id == entry.blob)
}

impl Aside {
    /// Moves every untracked file of `root` that `tree` has a file at out of the way.
    pub fn make(root: &Path, git_dir: &Path, tree: &str, label: &str) -> Result<Aside, String> {
        let here = untracked(root)?;
        let base = git_dir.join("cmux-auto").join("quarantine").join(label);
        let mut aside = Aside { root: root.to_owned(), moved: Vec::new() };
        for entry in entries(root, tree)?.into_iter().filter(|e| here.contains(&e.path)) {
            let file = root.join(&entry.path);
            let same = same_as(root, &file, &entry);
            let to = base.join(&entry.path);
            let moved = to
                .parent()
                .map_or(Ok(()), std::fs::create_dir_all)
                .and_then(|()| std::fs::rename(&file, &to));
            if let Err(e) = moved {
                aside.put_back();
                return Err(format!("keep {} aside: {e}", entry.path.display()));
            }
            aside.moved.push(Moved { path: entry.path, same, aside: to });
        }
        Ok(aside)
    }

    /// The snapshot is in: the files that were the snapshot's own are dropped; answers the
    /// paths of the ones that differed, which stay kept.
    pub fn done(self) -> Vec<PathBuf> {
        let mut kept = Vec::new();
        for moved in self.moved {
            if moved.same {
                let _ = std::fs::remove_file(&moved.aside);
            } else {
                kept.push(moved.path);
            }
        }
        kept
    }

    /// The snapshot did not go in: every file goes back where it was. Best effort.
    pub fn put_back(&mut self) {
        for moved in self.moved.drain(..) {
            let file = self.root.join(&moved.path);
            let _ = std::fs::remove_file(&file);
            let _ = std::fs::rename(&moved.aside, &file);
        }
    }
}
