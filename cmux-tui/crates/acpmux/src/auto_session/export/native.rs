//! The agent's own session files in a snapshot: Claude Code's project file, Codex's rollout,
//! pi's session, OpenCode's export, cmux-harness's journal. A new holder's agent resumes the
//! chat's `harnessSessionId` from them with its whole memory; without them it starts a fresh
//! conversation and is told a cut transcript.
//!
//! The files are the ones a manual move bundles, gathered by the same function
//! (`hub/transfer_agent_files.rs` `export_agent_files`), and go as chunks in the folder's pack,
//! so they count toward the chat's size limit with it.

use std::path::PathBuf;

use anyhow::{Context as _, Result};
use cmux_auto_session::chunks::Pack;
use cmux_auto_session::wire::NativeFile;
use serde_json::Value;

use super::folder::TooLarge;
use crate::hub::Hub;
use crate::store::SessionMeta;

/// The label of cmux-harness's durable state: its files sit in a bundle's `harness` folder,
/// not its `native` one.
pub(crate) const HARNESS_LABEL: &str = "cmux-harness";
/// cmux-harness's journal and session file, as a bundle names them under `harness`.
pub(crate) const HARNESS_FILES: [&str; 2] = ["journal.ndjson", "session.jsonl"];
/// What a bundle's manifest says of those two (`harness`: their sizes and digests), carried as
/// one more file of the label.
pub(crate) const HARNESS_SPEC: &str = "manifest.json";

/// One of the agent's files, read whole.
#[derive(Debug)]
pub(crate) struct AgentFile {
    pub label: String,
    /// Under a bundle's `native` folder (`harness` for [`HARNESS_LABEL`]).
    pub path: String,
    pub bytes: Vec<u8>,
}

/// Reads the agent's files of the chat `meta`. `max`: the most bytes they may add up to; past
/// it the error is [`TooLarge`], before any is read.
///
/// It blocks (file work, and `opencode export` for an OpenCode chat): call it off the async
/// workers.
pub(crate) fn read(hub: &Hub, meta: &SessionMeta, max: u64) -> Result<Vec<AgentFile>> {
    // The files as they sit in the agent's own store, before any is copied: a store past the
    // limit fills no scratch folder. (An OpenCode export and cmux-harness's state are sized
    // below, once they exist.)
    let mut sources = 0u64;
    for (_, source) in crate::native::locate(meta) {
        let size = std::fs::metadata(&source).map(|file| file.len()).unwrap_or(0);
        sources = sources.saturating_add(size);
        if sources > max {
            return Err(TooLarge.into());
        }
    }
    let scratch = tempfile::tempdir().context("a scratch folder")?;
    let dir = scratch.path().join("bundle");
    std::fs::create_dir_all(&dir).context("a scratch folder")?;
    let files = hub.export_agent_files(meta, &dir, scratch.path(), None)?;
    let mut named: Vec<(String, String, PathBuf)> = Vec::new();
    for entry in &files.native {
        let text = |key: &str| entry.get(key).and_then(Value::as_str);
        if let (Some(label), Some(path)) = (text("label"), text("path")) {
            named.push((label.to_owned(), path.to_owned(), dir.join("native").join(path)));
        }
    }
    let harness = !files.harness.is_null();
    if harness {
        for name in HARNESS_FILES {
            named.push((HARNESS_LABEL.to_owned(), name.to_owned(), dir.join("harness").join(name)));
        }
    }
    let mut total = 0u64;
    for (_, path, file) in &named {
        let size = std::fs::metadata(file).with_context(|| format!("the agent's {path}"))?.len();
        total = total.saturating_add(size);
        if total > max {
            return Err(TooLarge.into());
        }
    }
    let mut read = Vec::new();
    for (label, path, file) in named {
        let bytes = std::fs::read(&file).with_context(|| format!("the agent's {path}"))?;
        read.push(AgentFile { label, path, bytes });
    }
    if harness {
        let bytes = serde_json::to_vec(&files.harness).context("cmux-harness's manifest")?;
        read.push(AgentFile {
            label: HARNESS_LABEL.to_owned(),
            path: HARNESS_SPEC.to_owned(),
            bytes,
        });
    }
    Ok(read)
}

/// Adds the files to the snapshot's pack; the manifest's `native` list. The error is a pack
/// past its size limit.
pub(crate) fn add<'a>(
    pack: &mut Pack<'a>,
    files: &'a [AgentFile],
) -> Result<Vec<NativeFile>, TooLarge> {
    let mut native = Vec::new();
    for file in files {
        let chunks = pack.add(file.bytes.as_slice()).map_err(|_| TooLarge)?;
        native.push(NativeFile { label: file.label.clone(), path: file.path.clone(), chunks });
    }
    Ok(native)
}
