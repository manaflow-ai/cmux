//! What Session Info shows of the person's carried agent memory (cmuxterm-hq
//! plans/cloud/agent-memory-follows-user.md, step 4 "See it"): the files that follow the person to
//! every machine (the accepted head's manifest) and the proposed changes waiting for the person,
//! each with its diff, and the person's Accept or Drop of one proposal or a batch.
//!
//! The head is the folder `cmux link memory` keeps (cmux-tui `link/sync_cli/memory.rs`, `DirHead`):
//! `head.json` (`{generation, head: {revision, manifest}}`), `blobs/g<generation>/<sha256>` and
//! `proposals/<id>.json` (`{device, generation, base_revision, patch}`). [`head_dir`] is where both
//! look for it until the `AgentHome` service answers.
//!
//! Only an acceptance moves the head, and only the person accepts (the server refuses any other
//! caller). A proposal applies only while the head is still at the revision it was based on; one
//! based on an older head is refused, and the device proposes its change again on its next sync.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

/// The environment variable that names the head folder (`cmux link memory --head`'s default).
pub const HEAD_ENV: &str = "CMUX_AGENT_HOME_HEAD";

/// Largest diff Session Info is sent for one entry; a longer one is cut with a note.
const DIFF_MAX: usize = 16 * 1024;
/// Largest file diffed: the carried-file cap (`memory.rs` `FILE_MAX`).
const FILE_MAX: u64 = 1024 * 1024;

/// The head folder: `$CMUX_AGENT_HOME_HEAD`, else `agent-home-head` in acpmux's home when it exists.
pub fn head_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os(HEAD_ENV).filter(|dir| !dir.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    let dir = crate::config::home().join("agent-home-head");
    dir.is_dir().then_some(dir)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Item {
    sha256: String,
    #[serde(default)]
    mode: u32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct Accepted {
    revision: u64,
    manifest: BTreeMap<String, Item>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct HeadRead {
    generation: u64,
    head: Option<Accepted>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Proposal {
    device: String,
    generation: u64,
    base_revision: u64,
    patch: BTreeMap<String, Option<Item>>,
}

/// One head folder.
pub struct Head {
    root: PathBuf,
}

/// Serialises acceptances in this process: each is a read, a change and a write of `head.json`.
static ACCEPT: Mutex<()> = Mutex::new(());

/// Instructions or memory: Claude's notes under `.claude/projects/<p>/memory/` are memory, every
/// other carried file (the user `CLAUDE.md`, `AGENTS.md`, agents, commands, skills) instructions.
fn kind(path: &str) -> &'static str {
    let parts: Vec<&str> = path.split('/').collect();
    if matches!(parts.as_slice(), [".claude", "projects", _, "memory", _, ..]) {
        "memory"
    } else {
        "instructions"
    }
}

/// A proposal id as `DirHead::propose` makes one: 16 hex digits, never a path.
fn valid_id(id: &str) -> bool {
    id.len() == 16 && id.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_hash(sha256: &str) -> bool {
    sha256.len() == 64 && sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn write_json(path: &Path, value: &impl Serialize) -> std::io::Result<()> {
    let part = path.with_extension(format!("part-{}", std::process::id()));
    crate::home_fs::write(&part, serde_json::to_vec_pretty(value)?)?;
    crate::home_fs::rename(&part, path)
}

impl Head {
    pub fn at(root: PathBuf) -> Self {
        Self { root }
    }

    fn read(&self) -> std::io::Result<HeadRead> {
        match std::fs::read(self.root.join("head.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(HeadRead::default()),
            Err(error) => Err(error),
        }
    }

    /// A blob's text, when it is there, matches its hash and is UTF-8 under the cap.
    fn text(&self, generation: u64, sha256: &str) -> Option<String> {
        if !valid_hash(sha256) {
            return None;
        }
        let path = self.root.join("blobs").join(format!("g{generation}")).join(sha256);
        if std::fs::metadata(&path).ok()?.len() > FILE_MAX {
            return None;
        }
        let bytes = std::fs::read(path).ok()?;
        let hash: String = Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
        (hash == sha256).then(|| String::from_utf8(bytes).ok()).flatten()
    }

    fn size(&self, generation: u64, sha256: &str) -> Option<u64> {
        if !valid_hash(sha256) {
            return None;
        }
        let path = self.root.join("blobs").join(format!("g{generation}")).join(sha256);
        std::fs::metadata(path).ok().map(|meta| meta.len())
    }

    fn proposal_path(&self, id: &str) -> PathBuf {
        self.root.join("proposals").join(format!("{id}.json"))
    }

    fn proposal(&self, id: &str) -> Option<Proposal> {
        serde_json::from_slice(&std::fs::read(self.proposal_path(id)).ok()?).ok()
    }

    /// The listing Session Info draws: `{configured, generation, revision, carried, proposals}`.
    pub fn listing(&self) -> std::io::Result<Value> {
        let read = self.read()?;
        let Some(head) = read.head.as_ref() else {
            return Ok(json!({
                "configured": false,
                "generation": read.generation,
                "revision": null,
                "carried": [],
                "proposals": [],
            }));
        };
        let carried: Vec<Value> = head
            .manifest
            .iter()
            .map(|(path, item)| {
                json!({
                    "path": path,
                    "sha256": item.sha256,
                    "bytes": self.size(read.generation, &item.sha256),
                    "kind": kind(path),
                })
            })
            .collect();
        let mut proposals = Vec::new();
        if let Ok(entries) = std::fs::read_dir(self.root.join("proposals")) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                let Some(id) = name.strip_suffix(".json").filter(|id| valid_id(id)) else {
                    continue;
                };
                let Some(proposal) = self.proposal(id) else { continue };
                // A proposal from before a revocation is dead: it never applies, so it is not listed.
                if proposal.generation != read.generation {
                    continue;
                }
                let at = entry
                    .metadata()
                    .and_then(|meta| meta.modified())
                    .ok()
                    .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|since| since.as_millis() as u64);
                proposals.push((at, id.to_string(), self.describe(&read, head, id, &proposal, at)));
            }
        }
        // Newest first; the id keeps one order when two share a time.
        proposals.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        Ok(json!({
            "configured": true,
            "generation": read.generation,
            "revision": head.revision,
            "carried": carried,
            "proposals": proposals.into_iter().map(|(_, _, value)| value).collect::<Vec<_>>(),
        }))
    }

    fn describe(
        &self,
        read: &HeadRead,
        head: &Accepted,
        id: &str,
        proposal: &Proposal,
        at: Option<u64>,
    ) -> Value {
        let entries: Vec<Value> = proposal
            .patch
            .iter()
            .map(|(path, item)| {
                let before = head.manifest.get(path);
                let change = match (before, item) {
                    (_, None) => "remove",
                    (None, Some(_)) => "add",
                    (Some(_), Some(_)) => "change",
                };
                let old = before.and_then(|b| self.text(read.generation, &b.sha256));
                let new = item.as_ref().and_then(|i| self.text(read.generation, &i.sha256));
                let diff = match (before.is_some(), &old, item.is_some(), &new) {
                    // A side that should be text and is not (missing, binary, too big): no diff.
                    (true, None, _, _) | (_, _, true, None) => None,
                    _ => {
                        Some(diff(path, old.as_deref().unwrap_or(""), new.as_deref().unwrap_or("")))
                    }
                };
                json!({
                    "path": path,
                    "kind": kind(path),
                    "change": change,
                    "diff": diff,
                    "bytes": item.as_ref().and_then(|i| self.size(read.generation, &i.sha256)),
                })
            })
            .collect();
        json!({
            "id": id,
            "device": proposal.device,
            "baseRevision": proposal.base_revision,
            "at": at,
            "entries": entries,
        })
    }

    /// The person's Accept and Drop: `{accepted, dropped, refused: [{id, reason}], revision}`.
    /// Accepts apply in the order given, each against the head the one before it left.
    pub fn resolve(&self, accept: &[String], drop: &[String]) -> std::io::Result<Value> {
        let _held = ACCEPT.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut accepted = Vec::new();
        let mut dropped = Vec::new();
        let mut refused = Vec::new();
        let mut read = self.read()?;
        for id in accept {
            let refuse = |reason: &str| json!({"id": id, "reason": reason});
            if !valid_id(id) {
                refused.push(refuse("not a proposal id"));
                continue;
            }
            let Some(proposal) = self.proposal(id) else {
                refused.push(refuse("no such proposal: it was accepted or dropped already"));
                continue;
            };
            if proposal.generation != read.generation {
                refused.push(refuse("proposed before memory was turned off and on again"));
                continue;
            }
            let Some(head) = read.head.as_mut() else {
                refused.push(refuse("memory is off: there is no head to accept into"));
                continue;
            };
            if head.revision != proposal.base_revision {
                refused.push(refuse(
                    "your carried memory changed since this was proposed; its device proposes it again on its next sync",
                ));
                continue;
            }
            for (path, item) in proposal.patch {
                match item {
                    Some(item) => head.manifest.insert(path, item),
                    None => head.manifest.remove(&path),
                };
            }
            head.revision += 1;
            write_json(&self.root.join("head.json"), &read)?;
            let _ = crate::home_fs::remove_file(self.proposal_path(id));
            accepted.push(id.clone());
        }
        for id in drop {
            if !valid_id(id) {
                refused.push(json!({"id": id, "reason": "not a proposal id"}));
                continue;
            }
            match crate::home_fs::remove_file(self.proposal_path(id)) {
                Ok(()) => dropped.push(id.clone()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    dropped.push(id.clone())
                }
                Err(error) => return Err(error),
            }
        }
        Ok(json!({
            "accepted": accepted,
            "dropped": dropped,
            "refused": refused,
            "revision": read.head.as_ref().map(|head| head.revision),
        }))
    }
}

/// A unified diff of `old` to `new`, cut at [`DIFF_MAX`] on a line boundary.
fn diff(path: &str, old: &str, new: &str) -> String {
    let mut options = diffy::DiffOptions::new();
    options.set_original_filename(format!("a/{path}")).set_modified_filename(format!("b/{path}"));
    let text = options.create_patch(old, new).to_string();
    if text.len() <= DIFF_MAX {
        return text;
    }
    let mut kept = String::with_capacity(DIFF_MAX);
    for line in text.split_inclusive('\n') {
        if kept.len().saturating_add(line.len()) > DIFF_MAX {
            break;
        }
        kept.push_str(line);
    }
    format!("{kept}… diff cut at {} KB\n", DIFF_MAX / 1024)
}

#[cfg(test)]
#[path = "agent_home_tests.rs"]
mod tests;
