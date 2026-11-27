//! The leftover patch: what this machine's copy of a chat wrote after the last snapshot the
//! store acknowledged, once another holder runs the chat. It is written beside the chat and
//! never merged silently: the person shows, applies or discards it
//! (`_acpmux/auto_session/leftover`).
//!
//! Only the git form has one: a folder that went as a tar keeps no tree to cut against.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};

use super::folder;
use crate::auto_session::record::Leftover;
use crate::hub::{Hub, Session};

/// The most patch text `show` answers; a larger patch is listed by its files only.
const SHOW_MAX_BYTES: usize = 1 << 20;

/// Where the chat's leftover patch written at `now` goes, and whether that is the system's
/// shared scratch folder: beside its record, or there for a store that keeps nothing on disk.
/// The time is in the name, so a patch the person has not settled yet is never written over.
fn file_of(hub: &Hub, session: &Session, now: u64) -> (PathBuf, bool) {
    let name = format!("auto-leftover-{now}.patch");
    match hub.session_dir(&session.id) {
        Some(dir) => (dir.join(name), false),
        None => (std::env::temp_dir().join(format!("acpmux-{}-{name}", session.id)), true),
    }
}

/// Writes the patch. Beside the record it is written as every store file is. In the shared
/// scratch folder anyone can make a file first, so there it is made new and owner-only
/// (`create_new`, mode 0600, which follows no link): a path made first is refused, never
/// written through (security review of cmux#52931, item 5).
fn put(file: &Path, patch: &[u8], scratch: bool) -> anyhow::Result<()> {
    use anyhow::Context as _;
    use std::io::Write as _;
    if !scratch {
        return crate::config::write_atomic(file, patch);
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut out = options.open(file).with_context(|| format!("making {}", file.display()))?;
    out.write_all(patch).with_context(|| format!("writing {}", file.display()))
}

/// Writes what the chat's folder holds beyond the snapshot whose tree is `anchor`. None when
/// nothing differs or the folder is no checkout any more.
pub(crate) async fn write(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    anchor: &str,
    now: u64,
) -> Result<Option<Leftover>, String> {
    let cwd = session.meta().cwd;
    let (file, scratch) = file_of(hub, session, now);
    let anchor = anchor.to_owned();
    let cut = tokio::task::spawn_blocking(move || -> anyhow::Result<Option<Leftover>> {
        let Some(top) = folder::top_of(&cwd) else { return Ok(None) };
        let Some((files, patch)) = folder::since(&top, &anchor)? else { return Ok(None) };
        put(&file, &patch, scratch)?;
        Ok(Some(Leftover {
            files,
            at: now,
            path: file.to_string_lossy().into_owned(),
            top: top.to_string_lossy().into_owned(),
        }))
    })
    .await;
    match cut {
        Ok(Ok(leftover)) => Ok(leftover),
        Ok(Err(error)) => Err(format!("{error:#}")),
        Err(error) => Err(error.to_string()),
    }
}

/// `show`: the files the kept changes touch, and the patch when it is text of a readable size.
pub(crate) async fn show(leftover: &Leftover) -> Value {
    let path = PathBuf::from(&leftover.path);
    let patch = tokio::task::spawn_blocking(move || std::fs::read(path).ok())
        .await
        .ok()
        .flatten()
        .filter(|bytes| bytes.len() <= SHOW_MAX_BYTES)
        .and_then(|bytes| String::from_utf8(bytes).ok());
    let mut answer = json!({ "files": leftover.files });
    if let (Some(patch), Some(object)) = (patch, answer.as_object_mut()) {
        object.insert("patch".to_owned(), json!(patch));
    }
    answer
}

/// `apply`: the kept changes go into the chat's folder, merged where it moved on
/// (`apply.rs`): uncommitted work there stays, and a conflict changes nothing. The patch file
/// stays until this succeeds.
pub(crate) async fn apply(leftover: &Leftover) -> Result<(), String> {
    let (top, path) = (PathBuf::from(&leftover.top), PathBuf::from(&leftover.path));
    let applied = tokio::task::spawn_blocking(move || super::apply::apply(&top, &path)).await;
    match applied {
        Ok(Ok(())) => {
            discard(leftover).await;
            Ok(())
        }
        Ok(Err(error)) => Err(format!("{error:#}")),
        Err(error) => Err(error.to_string()),
    }
}

/// `discard`: the patch file goes.
pub(crate) async fn discard(leftover: &Leftover) {
    let path = Path::new(&leftover.path).to_path_buf();
    let _ = tokio::task::spawn_blocking(move || crate::home_fs::remove_file(path)).await;
}

#[cfg(all(test, unix))]
#[path = "leftover_tests.rs"]
mod tests;
