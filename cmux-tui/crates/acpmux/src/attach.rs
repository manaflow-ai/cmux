//! Files sent with a message between sessions: `acpmux send --attach FILE` (claude-sr2 scp'd Leo's
//! screenshots to big-red one at a time on 2026-10-25; Leo: "If this doesn't work as well as it
//! should, we need to improve ACP Mux.").
//!
//! The sender ([`block`], `acpmux send --attach`) adds each file to the prompt as a block marked
//! `_meta.acpmux.attachment {name}`: an image (its type read from its bytes) as an `image` block,
//! any other file as an embedded `resource`. The prompt then goes as every prompt goes (direct,
//! through the outbox, or whole over the peer link), so the send rules, the prompt id's run-once
//! ledger and the `--from` provenance are those of any message.
//!
//! The daemon that runs the session ([`receive`]) checks the caps and the type again and saves each
//! file owner-only at `<ACPMUX_HOME>/uploads/<session>/<prompt id>/<name>` (`file_uploads.rs`: a
//! purge and the age sweep delete it). An image stays an image block (the agent sees it, the
//! transcript draws it, `prompt_images.rs`); any other file becomes a `resource_link` to its copy.
//! A context note tells the agent where they are. Only the last component of the sender's name is
//! kept, made plain ([`safe_name`]). A resend of the same prompt id (the outbox's retry) is
//! answered from the ledger with the first run's outcome, and its own copy is deleted ([`Saved`]).
//!
//! Caps: the message is one JSON-RPC message on every hop (CLI, outbox record, peer link, agent),
//! at most `rpc::MAX_MESSAGE_BYTES` (15 MiB). 10 MiB is 13.3 MiB as base64, leaving room for the
//! text. A screenshot (a 5K Retina PNG is 3 to 7 MiB) fits in [`MAX_FILE_BYTES`]; a larger file
//! is a video or an archive, which `_acpmux/file_put` takes.

use crate::rpc::RpcError;
use base64::Engine;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// The `initialize` feature of a daemon that saves a message's attachments.
pub const FEATURE: &str = "sendAttach";
/// The largest file one attachment holds.
pub const MAX_FILE_BYTES: usize = 8 << 20;
/// The most one message's attachments hold together.
pub const MAX_MESSAGE_BYTES: usize = 10 << 20;
/// The most attachments one message takes.
pub const MAX_FILES: usize = 16;
/// The longest saved name, in bytes.
const MAX_NAME_BYTES: usize = 120;

fn refused(reason: &str, message: String) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({
        "reason": reason,
        "maxFileBytes": MAX_FILE_BYTES,
        "maxMessageBytes": MAX_MESSAGE_BYTES,
        "maxFiles": MAX_FILES,
    }))
}

fn mib(bytes: usize) -> String {
    format!("{:.1} MiB", bytes as f64 / f64::from(1 << 20))
}

/// One message's attachments, `(name, bytes)`, against the caps.
pub fn check_sizes(files: &[(String, usize)]) -> Result<(), RpcError> {
    let total: usize = files.iter().map(|(_, len)| len).sum();
    let message = if files.len() > MAX_FILES {
        let message = format!("{} attachments: a message takes at most {MAX_FILES}", files.len());
        return Err(refused("attach.tooMany", message));
    } else if let Some((name, len)) = files.iter().find(|(_, len)| *len > MAX_FILE_BYTES) {
        format!("{name} is {}: an attachment is at most {} MiB", mib(*len), MAX_FILE_BYTES >> 20)
    } else if total > MAX_MESSAGE_BYTES {
        let max = MAX_MESSAGE_BYTES >> 20;
        format!("the attachments are {} together: a message takes at most {max} MiB", mib(total))
    } else {
        return Ok(());
    };
    Err(refused("attach.tooLarge", message))
}

/// A sender's file name as one plain file name: its last path component, every character but a
/// letter, a digit, `.`, `-`, `_` or a space made `_`, no leading or trailing dot or space, at
/// most [`MAX_NAME_BYTES`]; `attachment` when nothing is left.
pub fn safe_name(raw: &str) -> String {
    let last = raw.rsplit(['/', '\\']).next().unwrap_or_default();
    let plain: String = last
        .chars()
        .map(|c| if c.is_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ') { c } else { '_' })
        .collect();
    let mut name = String::new();
    for c in plain.trim_matches(['.', ' ']).chars() {
        if name.len() + c.len_utf8() > MAX_NAME_BYTES {
            break;
        }
        name.push(c);
    }
    let name = name.trim_end_matches(['.', ' ']);
    if crate::hub::file_uploads::is_file_name(name) { name.to_owned() } else { "attachment".into() }
}

/// The image type of `bytes`, read from their magic number; None for anything else.
fn image_type(bytes: &[u8]) -> Option<&'static str> {
    crate::hub::prompt_images::sniffed_type(bytes).filter(|t| t.starts_with("image/"))
}

/// The prompt block of file `name` with `bytes`, marked as an attachment: an image block when the
/// bytes are an image, else an embedded resource.
pub fn block(name: &str, bytes: &[u8]) -> Value {
    let name = safe_name(name);
    let data = base64::engine::general_purpose::STANDARD.encode(bytes);
    let mark = json!({"acpmux": {"attachment": {"name": name}}});
    match image_type(bytes) {
        Some(mime) => {
            json!({"type": "image", "mimeType": mime, "data": data, "name": name, "_meta": mark})
        }
        None => {
            let mime = crate::hub::prompt_images::sniffed_type(bytes)
                .unwrap_or("application/octet-stream");
            json!({"type": "resource", "_meta": mark, "resource": {
                "uri": format!("attachment://{name}"), "mimeType": mime, "blob": data}})
        }
    }
}

fn mark(block: &Value) -> Option<&Value> {
    block.pointer("/_meta/acpmux/attachment").filter(|m| !m.is_null())
}

/// Whether any of `blocks` is an attachment.
pub fn any(blocks: &[Value]) -> bool {
    blocks.iter().any(|b| mark(b).is_some())
}

/// An attachment block's base64 bytes.
fn data_of(block: &Value) -> Option<&str> {
    match block.get("type").and_then(Value::as_str) {
        Some("image") => block.get("data"),
        Some("resource") => block.pointer("/resource/blob"),
        _ => None,
    }
    .and_then(Value::as_str)
}

/// `blocks`' attachments against the caps from their base64 length, before they are decoded or
/// sent on: a daemon forwarding a prompt to a peer refuses it before the link.
pub fn check_wire(blocks: &[Value]) -> Result<(), RpcError> {
    let sizes: Vec<_> = blocks
        .iter()
        .filter_map(|b| Some((mark(b)?, data_of(b).unwrap_or_default())))
        .map(|(m, data)| {
            let name = m.get("name").and_then(Value::as_str).unwrap_or("attachment");
            let pad = data.bytes().rev().take(2).take_while(|&b| b == b'=').count();
            (safe_name(name), (data.len() / 4 * 3).saturating_sub(pad))
        })
        .collect();
    check_sizes(&sizes)
}

/// For the daemon that runs session `session`: saves each attachment of `blocks` in a new folder
/// of the session's uploads, puts in its place what the agent gets (module docs), and answers
/// that folder ([`Saved`]). `web`: the prompt is a remote web client's, which writes no file here
/// (as `_acpmux/file_put`). Blocking: run it off the runtime.
pub fn receive(
    session: &str,
    web: bool,
    blocks: &mut Vec<Value>,
) -> Result<Option<Saved>, RpcError> {
    if !any(blocks) {
        return Ok(None);
    }
    if web {
        return Err(refused(
            "attach.remote",
            "a remote web connection cannot attach files".to_owned(),
        ));
    }
    check_wire(blocks)?;
    let mut files = Vec::new();
    let mut names = std::collections::HashSet::new();
    for (index, b) in blocks.iter().enumerate() {
        let Some(m) = mark(b) else { continue };
        let data = data_of(b).ok_or_else(|| {
            refused(
                "attach.invalid",
                "an attachment is an image block with data or a resource with a blob".to_owned(),
            )
        })?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(data)
            .map_err(|e| refused("attach.invalid", format!("an attachment is not base64: {e}")))?;
        let base = safe_name(m.get("name").and_then(Value::as_str).unwrap_or("attachment"));
        // Two files of one message under one name: the later ones get a number.
        let (mut name, mut n) = (base.clone(), 1);
        while !names.insert(name.clone()) {
            n += 1;
            name = safe_name(&format!("{n}-{base}"));
        }
        files.push((index, name, bytes));
    }
    check_sizes(&files.iter().map(|(_, name, b)| (name.clone(), b.len())).collect::<Vec<_>>())?;
    let uploads = crate::hub::file_uploads::session_dir(session)
        .ok_or_else(|| RpcError::invalid_params("no such chat"))?;
    // Named by this daemon's clock, which the uploads age sweep reads.
    let dir = uploads.join(uuid::Uuid::now_v7().to_string());
    let failed = |e: anyhow::Error| RpcError::internal(format!("cannot save an attachment: {e}"));
    crate::config::private_state_dir(&dir).map_err(failed)?;
    let (mut saved, mut staged) = (Vec::new(), Vec::new());
    for (index, name, bytes) in files {
        let path = dir.join(&name);
        crate::agent_tools::write_private(&path, &bytes).map_err(failed)?;
        let sniffed = crate::hub::prompt_images::sniffed_type(&bytes);
        let mime = sniffed.unwrap_or("application/octet-stream");
        saved.push(format!("- {} ({mime}, {})", path.display(), mib(bytes.len())));
        blocks[index] = match image_type(&bytes) {
            Some(mime) => {
                let image = json!({"type": "image", "mimeType": mime, "name": name,
                                   "data": data_of(&blocks[index]).unwrap_or_default()});
                // The transcript's copy, written here off the runtime (`keep` finds it).
                staged.extend(crate::hub::prompt_images::stage(std::slice::from_ref(&image)));
                image
            }
            None => {
                json!({"type": "resource_link", "uri": file_uri(&path), "name": name, "mimeType": mime})
            }
        };
    }
    blocks.push(json!({
        "type": "text",
        "text": format!(
            "<cmux-attachments-context>\nThe files attached to this message, saved on this machine:\n{}\n</cmux-attachments-context>",
            saved.join("\n")
        ),
        "_meta": {"acpmux": {"context": true}},
    }));
    Ok(Some(Saved { dir, staged, accepted: Arc::new(AtomicBool::new(false)) }))
}

/// The folder [`receive`] saved a message's files in, and the transcript copies it wrote, until
/// its prompt is answered.
pub struct Saved {
    dir: PathBuf,
    staged: Vec<String>,
    accepted: Arc<AtomicBool>,
}

type OnAccepted = Option<Box<dyn FnOnce(Value) + Send>>;

impl Saved {
    /// `on_accepted`, also noting whether the session took the prompt as a new run.
    pub fn watch(&self, on_accepted: OnAccepted) -> OnAccepted {
        let accepted = self.accepted.clone();
        Some(Box::new(move |v: Value| {
            if v.get("duplicate") != Some(&Value::Bool(true)) {
                accepted.store(true, Ordering::SeqCst);
            }
            if let Some(f) = on_accepted {
                f(v);
            }
        }))
    }

    /// Deletes the files nothing will read: the prompt was a resend the ledger answered with its
    /// first run's outcome (that run reads its own folder, so a retried delivery keeps one copy),
    /// or it was refused before it reached the session. A message an agent pair holds keeps them
    /// for its release (`agent_pairs.rs`).
    /// A transcript copy no prompt kept goes either way (`prompt_images::unstage`; a held
    /// message keeps its own when it is released).
    pub async fn settle(self, answer: &Result<Value, RpcError>) {
        let held = answer.as_ref().err().and_then(|e| e.data.as_ref()?.get("held"));
        let keep = self.accepted.load(Ordering::SeqCst) || held == Some(&Value::Bool(true));
        let (dir, staged) = (self.dir, self.staged);
        let _ = tokio::task::spawn_blocking(move || {
            crate::hub::prompt_images::unstage(&staged);
            if !keep {
                let _ = std::fs::remove_dir_all(dir);
            }
        })
        .await;
    }
}

/// The refusal for a peer on a build that would not save the files.
pub fn peer_unsupported(peer: &crate::peer::Peer) -> RpcError {
    let build = peer.remote_build().unwrap_or_else(|| "unknown".into());
    let message = format!(
        "peer {} runs acpmux build {build}, which does not take attachments; run `acpmux host update {}`",
        peer.name, peer.name
    );
    refused("attach.unsupported", message)
}

/// A `file://` URI for a saved file, percent-encoded.
fn file_uri(path: &Path) -> String {
    reqwest::Url::from_file_path(path)
        .map(String::from)
        .unwrap_or_else(|()| format!("file://{}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_senders_name_is_one_plain_file_name() {
        for (raw, want) in [
            ("shot.png", "shot.png"),
            ("../../etc/passwd", "passwd"),
            ("..\\..\\win.ini", "win.ini"),
            ("..", "attachment"),
            ("", "attachment"),
            (".bashrc", "bashrc"),
            ("a\u{202e}gnp.exe", "a_gnp.exe"),
            ("my shot ü.png", "my shot ü.png"),
            ("a\nb.txt", "a_b.txt"),
            ("trailing. ", "trailing"),
        ] {
            assert_eq!(safe_name(raw), want, "{raw:?}");
        }
        assert_eq!(safe_name(&"é".repeat(200)).len(), MAX_NAME_BYTES);
    }

    #[test]
    fn the_caps_name_themselves() {
        let ok = vec![("a".to_owned(), MAX_FILE_BYTES), ("b".to_owned(), 2 << 20)];
        assert!(check_sizes(&ok).is_ok());
        let one = check_sizes(&[("big.png".to_owned(), MAX_FILE_BYTES + 1)]).unwrap_err();
        assert!(one.message.contains("big.png") && one.message.contains("8 MiB"), "{one}");
        let two = vec![("a".to_owned(), 6 << 20), ("b".to_owned(), 6 << 20)];
        let total = check_sizes(&two).unwrap_err();
        assert!(total.message.contains("10 MiB"), "{total}");
        let many: Vec<_> = (0..=MAX_FILES).map(|i| (i.to_string(), 1)).collect();
        assert_eq!(check_sizes(&many).unwrap_err().data.unwrap()["reason"], "attach.tooMany");
    }

    #[test]
    fn the_whole_message_fits_one_frame() {
        let base64 = MAX_MESSAGE_BYTES.div_ceil(3) * 4;
        assert!(base64 + (1 << 20) < crate::rpc::MAX_MESSAGE_BYTES);
    }
}
