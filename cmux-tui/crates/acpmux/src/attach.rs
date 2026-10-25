//! Files sent with a message between sessions: `acpmux send --attach FILE` (claude-sr2,
//! 2026-10-25, copying Leo's screenshots to big-red one at a time with scp so lanes there could
//! see them; Leo: "If this doesn't work as well as it should, we need to improve ACP Mux.").
//!
//! The sender ([`blocks_from_paths`]) puts each file in the prompt as a block marked
//! `_meta.acpmux.attachment {name}`: an image (its type read from its bytes) as an ACP `image`
//! block, any other file as an embedded `resource` with its bytes as `blob`. The prompt then goes
//! the way every prompt goes: to a session here, through the outbox with `--no-wait`
//! (`server/outbox.rs`, which keeps it until the peer is back), or whole over the peer link to a
//! session on another host (`peer_forward.rs`). So the send rules, the prompt id's
//! once-only run and the `--from` provenance are the same as for any message.
//!
//! The daemon that runs the session ([`receive`]) checks the caps again, reads each file's type
//! from its bytes, and saves it owner-only (0600, folders 0700) in the session's uploads folder,
//! `<ACPMUX_HOME>/uploads/<session>/<prompt id>/<name>` (`hub/file_uploads.rs`: deleted with
//! the chat and by the age sweep). An image stays an image block, so the agent sees it and the
//! transcript draws it (`prompt_images.rs`); any other file becomes a `resource_link` to its saved
//! copy, which every harness opens with its own tools. A context note (not in the transcript)
//! tells the agent where they are saved. A name comes from the sender: only its last component is
//! kept, made plain ([`safe_name`]), so it never leaves that folder.
//!
//! Caps: [`MAX_FILE_BYTES`] a file, [`MAX_MESSAGE_BYTES`] and [`MAX_FILES`] a message. The whole
//! message is one JSON-RPC message on every hop (the CLI to its daemon, the outbox's record, the
//! peer link, the agent), which is at most `rpc::MAX_MESSAGE_BYTES` (15 MiB); 10 MiB is 13.3 MiB
//! as base64 and leaves room for the text. A screenshot (a 5K Retina PNG is 3 to 7 MiB) fits one
//! file whole; a larger file is a video or an archive, which `_acpmux/file_put` takes.
//!
//! A retried delivery saves no second copy: a prompt id that is a UUIDv7 (the CLI's) names the
//! folder, so the outbox's retry (same prompt id, `resend`) writes the same files again.

use crate::rpc::RpcError;
use anyhow::Context;
use base64::Engine;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

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
    if files.len() > MAX_FILES {
        return Err(refused(
            "attach.tooMany",
            format!("{} attachments: a message takes at most {MAX_FILES}", files.len()),
        ));
    }
    if let Some((name, len)) = files.iter().find(|(_, len)| *len > MAX_FILE_BYTES) {
        return Err(refused(
            "attach.tooLarge",
            format!(
                "{name} is {}: an attachment is at most {} MiB (shrink it, or send its path)",
                mib(*len),
                MAX_FILE_BYTES >> 20
            ),
        ));
    }
    let total: usize = files.iter().map(|(_, len)| len).sum();
    if total > MAX_MESSAGE_BYTES {
        return Err(refused(
            "attach.tooLarge",
            format!(
                "the attachments are {} together: a message takes at most {} MiB (send them in more than one)",
                mib(total),
                MAX_MESSAGE_BYTES >> 20
            ),
        ));
    }
    Ok(())
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
            let mime =
                crate::hub::prompt_images::sniffed_type(bytes).unwrap_or("application/octet-stream");
            json!({"type": "resource", "_meta": mark, "resource": {
                "uri": format!("attachment://{name}"), "mimeType": mime, "blob": data}})
        }
    }
}

/// The attachment blocks of the files at `paths` (`acpmux send --attach`). Refused past the caps
/// from each file's size before any is read.
pub fn blocks_from_paths(paths: &[PathBuf]) -> anyhow::Result<Vec<Value>> {
    let label = |path: &Path| path.display().to_string();
    let mut sizes = Vec::with_capacity(paths.len());
    for path in paths {
        let meta = std::fs::metadata(path).with_context(|| format!("cannot attach {}", label(path)))?;
        anyhow::ensure!(meta.is_file(), "cannot attach {}: not a file", label(path));
        sizes.push((label(path), usize::try_from(meta.len()).unwrap_or(usize::MAX)));
    }
    check_sizes(&sizes).map_err(|e| anyhow::anyhow!(e.message))?;
    let mut read = Vec::with_capacity(paths.len());
    for path in paths {
        read.push(std::fs::read(path).with_context(|| format!("cannot attach {}", label(path)))?);
    }
    // A file that grew since: the bytes sent are what count.
    let sizes: Vec<_> = paths.iter().zip(&read).map(|(p, b)| (label(p), b.len())).collect();
    check_sizes(&sizes).map_err(|e| anyhow::anyhow!(e.message))?;
    Ok(paths
        .iter()
        .zip(read)
        .map(|(path, bytes)| {
            let name = path.file_name().map(|n| n.to_string_lossy()).unwrap_or_default();
            block(&name, &bytes)
        })
        .collect())
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

/// For the daemon that runs session `session`: saves each attachment of `blocks` (prompt
/// `prompt_id`) in the session's uploads and puts in its place what the agent gets (module docs).
/// `web`: the prompt is a remote web client's, which writes no file here (as `_acpmux/file_put`).
/// Blocking: run it off the runtime.
pub fn receive(
    session: &str,
    prompt_id: Option<&str>,
    web: bool,
    blocks: &mut Vec<Value>,
) -> Result<(), RpcError> {
    if !any(blocks) {
        return Ok(());
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
    let folder = prompt_id
        .and_then(|id| uuid::Uuid::try_parse(id).ok())
        .filter(|id| id.get_version_num() == 7)
        .unwrap_or_else(uuid::Uuid::now_v7)
        .to_string();
    let dir = uploads.join(folder);
    let failed = |e: anyhow::Error| RpcError::internal(format!("cannot save an attachment: {e}"));
    crate::config::private_state_dir(&dir).map_err(failed)?;
    let mut saved = Vec::new();
    for (index, name, bytes) in files {
        let path = dir.join(&name);
        crate::agent_tools::write_private(&path, &bytes).map_err(failed)?;
        let sniffed = crate::hub::prompt_images::sniffed_type(&bytes);
        let mime = sniffed.unwrap_or("application/octet-stream");
        saved.push(format!("- {} ({mime}, {})", path.display(), mib(bytes.len())));
        blocks[index] = match image_type(&bytes) {
            Some(mime) => json!({"type": "image", "mimeType": mime, "name": name,
                                 "data": data_of(&blocks[index]).unwrap_or_default()}),
            None => json!({"type": "resource_link", "uri": file_uri(&path), "name": name, "mimeType": mime}),
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
    Ok(())
}

/// A `file://` URI for a saved file, percent-encoded.
fn file_uri(path: &Path) -> String {
    reqwest::Url::from_file_path(path)
        .map(String::from)
        .unwrap_or_else(|()| format!("file://{}", path.display()))
}

/// Drops the bytes of `request`'s attachments (`session/prompt` params): a delivery the outbox
/// settled keeps its record for a day (`hub/outbox.rs`), and every change rewrites the file.
pub fn strip(request: &mut Value) {
    let Some(blocks) = request.get_mut("prompt").and_then(Value::as_array_mut) else { return };
    for b in blocks.iter_mut().filter(|b| mark(b).is_some()) {
        if let Some(o) = b.as_object_mut() {
            o.remove("data");
        }
        if let Some(o) = b.get_mut("resource").and_then(Value::as_object_mut) {
            o.remove("blob");
        }
    }
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

    #[test]
    fn files_become_image_or_resource_blocks_by_their_bytes() {
        let dir = std::env::temp_dir().join(format!("acpmux-attach-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let png = dir.join("shot.txt");
        std::fs::write(&png, b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR").unwrap();
        let notes = dir.join("notes.png");
        std::fs::write(&notes, b"plain text").unwrap();
        let blocks = blocks_from_paths(&[png, notes]).unwrap();
        assert_eq!(blocks[0]["type"], "image");
        assert_eq!(blocks[0]["mimeType"], "image/png");
        assert_eq!(blocks[0]["_meta"]["acpmux"]["attachment"]["name"], "shot.txt");
        assert_eq!(blocks[1]["type"], "resource");
        assert_eq!(blocks[1]["resource"]["mimeType"], "application/octet-stream");
        assert!(check_wire(&blocks).is_ok());
        // Past the cap, from its size alone; a missing file names itself.
        let big = dir.join("big.bin");
        std::fs::File::create(&big).unwrap().set_len(MAX_FILE_BYTES as u64 + 1).unwrap();
        let e = blocks_from_paths(&[big]).unwrap_err().to_string();
        assert!(e.contains("big.bin") && e.contains("8 MiB"), "{e}");
        let e = blocks_from_paths(&[dir.join("gone.png")]).unwrap_err().to_string();
        assert!(e.contains("gone.png"), "{e}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_settled_delivery_keeps_no_bytes() {
        let mut request = json!({"prompt": [
            {"type": "text", "text": "t"},
            block("a.png", b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR"),
            block("b.txt", b"b"),
            {"type": "image", "mimeType": "image/png", "data": "AAAA"},
        ]});
        strip(&mut request);
        assert!(request["prompt"][1].get("data").is_none());
        assert!(request["prompt"][2]["resource"].get("blob").is_none());
        assert_eq!(request["prompt"][2]["resource"]["uri"], "attachment://b.txt");
        // Only attachments: an app's own image block is left as it is.
        assert_eq!(request["prompt"][3]["data"], "AAAA");
    }
}
