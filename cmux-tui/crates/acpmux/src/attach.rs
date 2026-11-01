//! Files sent with a message between sessions: `acpmux send --attach FILE` (claude-sr2 scp'd Leo's
//! screenshots to big-red one at a time on 2026-10-25; Leo: "If this doesn't work as well as it
//! should, we need to improve ACP Mux.").
//!
//! The sender ([`blocks_for`]: `acpmux send --attach`, cmux-subsessions `send_message`) adds
//! the files to the prompt one of two ways, never refusing one for its size or their number (Leo,
//! 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE"):
//!
//! - Small ones that fit one message with the text ([`fits_inline`]) go inline, each a block
//!   marked `_meta.acpmux.attachment {name}`: an image (its type read from its bytes) as an
//!   `image` block, any other file as an embedded `resource`.
//! - Otherwise each file is uploaded to the receiving chat first, in chunks of at most
//!   `file_uploads::CHUNK_BYTES` read from disk as they go, and the prompt names it by reference
//!   (`prompt_uploads.rs`): the daemon that runs the chat puts an image the agent can take inline
//!   and gives it every other file by its path. The sender says how far it is, retries what a
//!   flaky link loses, and resumes an upload a sender that died began (`attach/upload.rs`).
//!
//! The prompt then goes as every prompt goes (direct, through the outbox, or whole over the peer
//! link), so the send rules, the prompt id's run-once ledger and the `--from` provenance are
//! those of any message.
//!
//! The daemon that runs the session ([`receive`]) checks the type again and saves each inline
//! file owner-only at `<ACPMUX_HOME>/uploads/<session>/<uuidv7>/<name>` (`file_uploads.rs`: a
//! purge and the age sweep delete it, also one a crash left). An image stays an image block (the agent sees it, the
//! transcript draws it, `prompt_images.rs`); any other file becomes a `resource_link` to its copy.
//! A context note tells the agent where they are. Only the last component of the sender's name is
//! kept, made plain ([`safe_name`]). A resend of the same prompt id (the outbox's retry) is
//! answered from the ledger with the first run's outcome, and its own copy is deleted ([`Saved`]).
//!
//! No cap: an inline message is one JSON-RPC message on every hop (CLI, outbox record, peer link,
//! agent), at most `rpc::MAX_MESSAGE_BYTES` (31 MiB), so the senders go by reference before that.
//! [`check_wire`] answers a raw protocol sender whose inline request would not fit one message on
//! the next hop, rather than let a hop drop it.

use crate::client::Client;
use crate::rpc::{RpcError, method};
use anyhow::Context;
use base64::Engine;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

mod upload;
pub use upload::Say;

/// The `initialize` feature of a daemon that saves a message's attachments.
pub const FEATURE: &str = "sendAttach";
/// The most files a message carries inline; more go by reference. Never a refusal.
const INLINE_FILES: usize = 16;
/// The most bytes a message's files carry inline together; past it they go by reference.
const INLINE_TOTAL_BYTES: u64 = crate::prompt_uploads::INLINE_PROMPT_BYTES as u64;
/// The largest file put inline: an image the agent's API takes inline. A larger one goes by
/// reference, so the agent gets it by its path.
const INLINE_FILE_BYTES: u64 = crate::prompt_uploads::INLINE_IMAGE_BYTES as u64;
/// Room left for a block's own fields and the prompt's metadata when counting an inline message.
const BLOCK_SLACK: usize = 1 << 10;
const META_SLACK: usize = 64 << 10;
/// The longest saved name, in bytes.
const MAX_NAME_BYTES: usize = 120;

fn refused(reason: &str, message: String) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

fn mib(bytes: usize) -> String {
    format!("{:.1} MiB", bytes as f64 / f64::from(1 << 20))
}

/// Whether files of `sizes` go inline in one message with `text`: few and small enough, and the
/// whole message, as base64 with its text, within one JSON-RPC message on every hop. Otherwise
/// they go by reference ([`blocks_for`]); this never refuses a send.
pub fn fits_inline(sizes: &[u64], text: &str) -> bool {
    let total: u64 = sizes.iter().sum();
    if sizes.len() > INLINE_FILES
        || sizes.iter().any(|&n| n > INLINE_FILE_BYTES)
        || total > INLINE_TOTAL_BYTES
    {
        return false;
    }
    let text = serde_json::to_string(text).map_or(usize::MAX, |t| t.len());
    let base64 = usize::try_from(total.div_ceil(3) * 4).unwrap_or(usize::MAX);
    let wire = base64
        .saturating_add(text)
        .saturating_add(sizes.len() * BLOCK_SLACK)
        .saturating_add(META_SLACK + FRAME_SLACK);
    wire <= crate::rpc::MAX_MESSAGE_BYTES
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

/// The blocks of the files at `paths` for a message of `text` to chat `session`, sent through
/// `daemon` (`acpmux send --attach`, the cmux-subsessions `send_message` tool): inline when they
/// fit ([`fits_inline`]), else each uploaded to the chat and named by reference, whatever their
/// size or number. A file that cannot be read, or an upload the daemon refuses, fails the send.
/// `say` gets the uploads' progress lines (`attach/upload.rs`).
pub async fn blocks_for(
    daemon: &Client,
    session: &str,
    text: &str,
    paths: &[PathBuf],
    say: Say<'_>,
) -> anyhow::Result<Vec<Value>> {
    let mut sizes = Vec::with_capacity(paths.len());
    for path in paths {
        let label = path.display();
        let meta =
            tokio::fs::metadata(path).await.with_context(|| format!("cannot attach {label}"))?;
        anyhow::ensure!(meta.is_file(), "cannot attach {label}: not a file");
        sizes.push(meta.len());
    }
    if fits_inline(&sizes, text) {
        let paths = paths.to_vec();
        return tokio::task::spawn_blocking(move || inline_blocks(&paths)).await?;
    }
    // Checked before any byte is sent, so no upload is left behind for a prompt that would be
    // refused: this daemon resolves references, and a peer's chat is refused at the begin
    // (`forPrompt`) when its daemon does not (`server/peer_forward.rs`).
    if !daemon.daemon_lists(crate::prompt_uploads::FEATURE) {
        let build = daemon.daemon_build().unwrap_or_else(|| "unknown".into());
        anyhow::bail!(
            "these files do not fit one message, and the running acpmux daemon (build {build}) \
             predates files sent by reference: restart it on this build (`acpmux daemon shutdown`; \
             the next command starts it)"
        );
    }
    // Upload calls name the chat by its id (a peer's chat by `peer/id`).
    let info = daemon.request(method::MUX_INFO, json!({"sessionId": session})).await?;
    let chat = match (info.get("sessionId").and_then(Value::as_str), info.get("peer")) {
        (Some(id), Some(Value::String(peer))) => format!("{peer}/{id}"),
        (Some(id), _) => id.to_owned(),
        (None, _) => session.to_owned(),
    };
    // Every file's bytes first, then every finish: a file that fails cancels the uploads begun so
    // far, none of them finished yet, so nothing is left behind for a send that never happens.
    let mut sent: Vec<Sent> = Vec::with_capacity(paths.len());
    let mut failure = None;
    let mut progress = upload::Progress::start(say, &chat, &sizes);
    for (path, size) in paths.iter().zip(sizes) {
        match upload::upload(daemon, &chat, path, size, &mut progress).await {
            Ok(one) => sent.push(one),
            Err((e, begun)) => {
                sent.extend(begun);
                failure = Some(e);
                break;
            }
        }
    }
    if failure.is_none() {
        let since = std::time::Instant::now();
        for one in &sent {
            let finish = json!({"sessionId": chat, "uploadId": one.id, "fileName": one.name,
                "size": one.size});
            let what = format!("finishing {}", one.name);
            // A repeated finish answers the same, so one whose answer the link lost is asked again.
            let finished = upload::retrying(daemon, say, &what, since, || {
                daemon.request(method::MUX_FILE_PUT_FINISH, finish.clone())
            });
            if let Err(e) = finished.await {
                failure = Some(upload::failure(daemon, &one.name, e));
                break;
            }
        }
    }
    // Finished: a later send of the same files uploads them again, for its own prompt. A record
    // that cannot be removed would let a later send take this prompt's upload as its own, so the
    // send fails instead and its uploads go.
    if failure.is_none()
        && let Some(stuck) = sent.iter().filter_map(|one| one.record.as_ref()).find(|r| !r.forget())
    {
        failure = Some(anyhow::anyhow!(
            "cannot remove the upload record {}; the files were not sent",
            stuck.path().display()
        ));
    }
    if let Some(e) = failure {
        // A link that stopped: each upload with a record stays for the same send to resume
        // (`attach/upload.rs`), and the age sweep takes it if that never comes. The rest go.
        let stopped = e.downcast_ref::<upload::LinkStopped>().is_some();
        let mut kept = 0;
        for one in &sent {
            if stopped && one.record.is_some() {
                kept += 1;
                continue;
            }
            let cancel = json!({"sessionId": chat, "uploadId": one.id, "ownerToken": one.owner});
            let _ = daemon.request(method::MUX_FILE_PUT_CANCEL, cancel).await;
            one.forget();
        }
        if kept > 0 {
            return Err(anyhow::anyhow!("{e:#}; run the same send again to resume the upload"));
        }
        return Err(e);
    }
    progress.finished();
    Ok(sent.iter().map(Sent::block).collect())
}

fn inline_blocks(paths: &[PathBuf]) -> anyhow::Result<Vec<Value>> {
    paths
        .iter()
        .map(|path| {
            let bytes =
                std::fs::read(path).with_context(|| format!("cannot attach {}", path.display()))?;
            let name = path.file_name().map(|n| n.to_string_lossy()).unwrap_or_default();
            Ok(block(&name, &bytes))
        })
        .collect()
}

/// A file whose bytes were sent to a chat, not yet finished.
struct Sent {
    id: String,
    /// The owner token its begin gave (`file_uploads::begin`); none from an older daemon.
    owner: Option<String>,
    name: String,
    size: u64,
    /// Its first bytes, which say whether it is an image.
    head: Vec<u8>,
    /// The record a later send resumes it by, held by this sender (`attach/upload.rs`); none
    /// from an older daemon, or while another sender holds it.
    record: Option<upload::Record>,
}

impl Sent {
    /// Removes its resume record: it was cancelled.
    fn forget(&self) {
        if let Some(record) = &self.record {
            record.forget();
        }
    }

    /// The block that names the upload (`prompt_uploads.rs`), marked as this prompt's own: the
    /// daemon deletes it if the prompt is refused before the chat takes it (`Saved`).
    fn block(&self) -> Value {
        let (id, name) = (&self.id, &self.name);
        let mut upload = json!({"uploadId": id, "fileName": name});
        if let Some(token) = &self.owner {
            upload.set("owned", json!(token));
        }
        let meta = json!({"acpmux": {"upload": upload}});
        match image_type(&self.head) {
            Some(mime) => json!({"type": "image", "mimeType": mime, "_meta": meta}),
            None => json!({"type": "resource_link", "name": name,
                "uri": format!("{}{id}", crate::prompt_uploads::URI_SCHEME), "_meta": meta}),
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

/// Whether every one of `blocks` is an attachment.
pub fn all(blocks: &[Value]) -> bool {
    blocks.iter().all(|b| mark(b).is_some())
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

/// Whether a `session/prompt` request with inline attachments, its text and metadata too, fits
/// one JSON-RPC message on the next hop (which adds its provenance), before it is decoded or sent
/// on. Not a cap on files: [`blocks_for`] sends any that would not fit by reference, so only a
/// raw protocol sender meets this, and it is answered rather than dropped by a hop.
pub fn check_wire(request: &Value) -> Result<(), RpcError> {
    let blocks = request.get("prompt").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    if !any(blocks) {
        return Ok(());
    }
    let mut len = Count(0);
    let _ = serde_json::to_writer(&mut len, request);
    if len.0 + FRAME_SLACK <= crate::rpc::MAX_MESSAGE_BYTES {
        return Ok(());
    }
    let max = crate::rpc::MAX_MESSAGE_BYTES >> 20;
    let message = format!(
        "the message is {} with its inline attachments: one JSON-RPC message is at most {max} \
         MiB; send the files as uploads named by reference (`acpmux send --attach` does)",
        mib(len.0 + FRAME_SLACK)
    );
    Err(refused("attach.tooLarge", message))
}

/// Room [`check_wire`] leaves for the JSON-RPC envelope and what a hop adds (a forwarding
/// daemon's provenance).
const FRAME_SLACK: usize = 16 << 10;

/// Counts the bytes written to it.
struct Count(usize);

impl std::io::Write for Count {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0 += bytes.len();
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
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
    let uploads = crate::hub::file_uploads::session_dir(session)
        .ok_or_else(|| RpcError::invalid_params("no such chat"))?;
    // Named by this daemon's clock, which the uploads age sweep reads.
    let dir = uploads.join(uuid::Uuid::now_v7().to_string());
    // From here the folder is the message's: a failure deletes it, files saved so far included.
    let saved_dir = Saved::new(session, Vec::new()).in_dir(dir.clone());
    let failed = |e: anyhow::Error| RpcError::internal(format!("cannot save an attachment: {e}"));
    crate::config::private_state_dir(&dir).map_err(failed)?;
    let mut saved = Vec::new();
    for (index, name, bytes) in files {
        let path = dir.join(&name);
        crate::agent_tools::write_private(&path, &bytes).map_err(failed)?;
        let sniffed = crate::hub::prompt_images::sniffed_type(&bytes);
        let mime = sniffed.unwrap_or("application/octet-stream");
        saved.push(format!("- {} ({mime}, {})", path.display(), mib(bytes.len())));
        let Some(block) = blocks.get_mut(index) else { continue };
        *block = match image_type(&bytes) {
            Some(mime) => json!({"type": "image", "mimeType": mime, "name": name,
                                 "data": data_of(block).unwrap_or_default()}),
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
    Ok(Some(saved_dir))
}

/// The folder [`receive`] saved a message's files in, until its prompt is answered. Dropped
/// unsettled (a failure, or the request dropped before its answer), it deletes the folder unless
/// the session took the prompt.
pub struct Saved {
    dir: Option<PathBuf>,
    /// The folders of uploads the prompt names as its own (`_meta.acpmux.upload.owned`,
    /// [`blocks_for`]): deleted only when the prompt is refused before the session answers it.
    /// A duplicate keeps them, since the first run may read the same uploads (an outbox retry).
    owned: Vec<PathBuf>,
    session: String,
    /// Set when the session takes the prompt as a new run: whether it queued, and its id.
    accepted: Arc<Mutex<Option<(bool, String)>>>,
    /// Set when the session answers the prompt at all: a new run or a duplicate.
    answered: Arc<std::sync::atomic::AtomicBool>,
}

type OnAccepted = Option<Box<dyn FnOnce(Value) + Send>>;

impl Saved {
    /// The guard of a prompt to session `session` that names uploads `owned` as its own, with no
    /// inline files saved ([`receive`] makes the one that has them).
    pub fn new(session: &str, owned: Vec<PathBuf>) -> Self {
        Saved {
            dir: None,
            owned,
            session: session.to_owned(),
            accepted: Arc::default(),
            answered: Arc::default(),
        }
    }

    /// This guard, for the folder `dir` its inline files were saved in.
    fn in_dir(mut self, dir: PathBuf) -> Self {
        self.dir = Some(dir);
        self
    }

    /// `saved` (from [`receive`]), or a new guard, that also deletes uploads `owned` when the
    /// prompt is refused; None when there is nothing to guard.
    pub fn with_owned(saved: Option<Saved>, session: &str, owned: Vec<PathBuf>) -> Option<Saved> {
        match saved {
            Some(mut saved) => {
                saved.owned.extend(owned);
                Some(saved)
            }
            None if owned.is_empty() => None,
            None => Some(Saved::new(session, owned)),
        }
    }

    /// `on_accepted`, also noting whether the session took the prompt as a new run.
    pub fn watch(&self, on_accepted: OnAccepted) -> OnAccepted {
        let accepted = self.accepted.clone();
        let answered = self.answered.clone();
        Some(Box::new(move |v: Value| {
            answered.store(true, std::sync::atomic::Ordering::SeqCst);
            if v.get("duplicate") != Some(&Value::Bool(true)) {
                let queued = v.get("queued") == Some(&Value::Bool(true));
                let id = v.get("promptId").and_then(Value::as_str).unwrap_or_default().to_owned();
                *accepted.lock().unwrap_or_else(|e| e.into_inner()) = Some((queued, id));
            }
            if let Some(f) = on_accepted {
                f(v);
            }
        }))
    }

    /// Deletes the files nothing will read, its inline files and the uploads it names as its own
    /// alike: the prompt was refused before it reached the session, or it was queued and then
    /// left the queue unrun (withdrawn, superseded, refused when its turn came). A resend the
    /// ledger answered with its first run's outcome keeps none of its inline files (that run reads
    /// its own folder, so a retried delivery keeps one copy) and all of its uploads (that run
    /// reads the same ones). A message an agent pair holds keeps both until it is dropped
    /// ([`held_dropped`]) or its release is answered ([`held_released`]); a resend of one held
    /// already keeps none of its own.
    pub async fn settle(mut self, hub: &Arc<crate::hub::Hub>, answer: &Result<Value, RpcError>) {
        let accepted = self.accepted.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let data = answer.as_ref().err().and_then(|e| e.data.as_ref());
        let flag = |k| data.and_then(|d| d.get(k)) == Some(&Value::Bool(true));
        let held = (flag("held") && !flag("resent"))
            .then(|| data.and_then(|d| d.get("promptId")).and_then(Value::as_str))
            .flatten()
            .map(str::to_owned);
        let withdrawn = answer.as_ref().ok().and_then(|v| v.pointer("/_meta/acpmux/withdrawn"))
            == Some(&Value::Bool(true));
        let failed = answer.is_err();
        let answered = self.answered.load(std::sync::atomic::Ordering::SeqCst);
        let resent_held = flag("held");
        let (hub, session) = (hub.clone(), self.session.clone());
        let (dir, owned) = (self.dir.take(), std::mem::take(&mut self.owned));
        let _ = tokio::task::spawn_blocking(move || {
            let taken = accepted.is_some();
            // Whether it ran or may still run: its files stay.
            let keep = match accepted {
                None => match held {
                    Some(prompt_id) => {
                        held_dirs().insert((session.clone(), prompt_id), Held { dir, owned });
                        return;
                    }
                    None => false,
                },
                Some(_) if withdrawn => false,
                // Refused when its turn came, or its turn failed: kept if it ran.
                Some((true, id)) if failed => hub.ran_prompt(&session, &id),
                Some(_) => true,
            };
            // Not taken: a duplicate (answered) or the resend of a held message keeps the uploads
            // the first one reads; one refused before the session answered it does not.
            let keep_owned = keep || (!taken && (!failed || answered || resent_held));
            if !keep_owned {
                remove_uploads(&owned);
            }
            if let Some(dir) = dir.filter(|_| !keep) {
                let _ = std::fs::remove_dir_all(dir);
            }
        })
        .await;
    }
}

/// The files of a message an agent pair holds: its inline files' folder and its own uploads.
struct Held {
    dir: Option<PathBuf>,
    owned: Vec<PathBuf>,
}

impl Held {
    /// Deletes them all. Blocking.
    fn remove(self) {
        remove_uploads(&self.owned);
        if let Some(dir) = self.dir {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}

/// The files of messages an agent pair holds, by receiving session and prompt id, until
/// [`held_dropped`] or [`held_released`]. One held across a daemon restart is not here: its files
/// go with the uploads age sweep or the chat's deletion.
fn held_dirs() -> std::sync::MutexGuard<'static, BTreeMap<(String, String), Held>> {
    static HELD: Mutex<BTreeMap<(String, String), Held>> = Mutex::new(BTreeMap::new());
    HELD.lock().unwrap_or_else(|e| e.into_inner())
}

/// A message an agent pair held was dropped (`agent_pairs.rs`): its files go.
pub fn held_dropped(session: &str, prompt_id: &str) {
    if let Some(held) = held_dirs().remove(&(session.to_owned(), prompt_id.to_owned())) {
        off_runtime(move || held.remove());
    }
}

/// A held message the pair released into session `session` was answered (it ran, or it left
/// the queue unrun, withdrawn or refused): its files stay only if the session's log shows it ran.
pub async fn held_released(hub: &Arc<crate::hub::Hub>, session: &str, prompt_id: &str) {
    let key = (session.to_owned(), prompt_id.to_owned());
    let Some(held) = held_dirs().remove(&key) else { return };
    let hub = hub.clone();
    let _ = tokio::task::spawn_blocking(move || {
        if !hub.ran_prompt(&key.0, &key.1) {
            held.remove();
        }
    })
    .await;
}

/// Runs blocking `f` off the runtime when there is one, else here.
fn off_runtime(f: impl FnOnce() + Send + 'static) {
    match tokio::runtime::Handle::try_current() {
        Ok(runtime) => drop(runtime.spawn_blocking(f)),
        Err(_) => f(),
    }
}

/// Deletes folder `dir` off the runtime when there is one.
fn remove_soon(dir: PathBuf) {
    off_runtime(move || drop(std::fs::remove_dir_all(dir)));
}

impl Drop for Saved {
    fn drop(&mut self) {
        let accepted = self.accepted.lock().unwrap_or_else(|e| e.into_inner()).is_some();
        if let Some(dir) = self.dir.take().filter(|_| !accepted) {
            remove_soon(dir);
        }
        // Dropped unanswered (the request went before its answer): the prompt never ran.
        let owned = std::mem::take(&mut self.owned);
        if !owned.is_empty() && !self.answered.load(std::sync::atomic::Ordering::SeqCst) {
            off_runtime(move || remove_uploads(&owned));
        }
    }
}

/// The folders of the uploads a prompt names as its own (`prompt_uploads::owned`) while the
/// daemon checks it: dropped before [`OwnedUploads::take`] (a refusal before the session saw
/// the prompt), it deletes them. [`Saved`] then guards them until the session answers.
pub struct OwnedUploads(pub Vec<PathBuf>);

impl OwnedUploads {
    /// The folders, for [`Saved::with_owned`]; this guard then deletes nothing.
    pub fn take(&mut self) -> Vec<PathBuf> {
        std::mem::take(&mut self.0)
    }
}

impl Drop for OwnedUploads {
    fn drop(&mut self) {
        let owned = self.take();
        if owned.is_empty() {
            return;
        }
        off_runtime(move || remove_uploads(&owned));
    }
}

/// Deletes upload folders `dirs` (`file_uploads::remove_uploads`). Blocking.
fn remove_uploads(dirs: &[PathBuf]) {
    if !dirs.is_empty() {
        crate::hub::file_uploads::remove_uploads(dirs);
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

/// Drops the bytes of `request`'s attachments (`session/prompt` params): a delivery the outbox
/// settled keeps its record for a day (`hub/outbox.rs`).
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
    fn small_files_go_inline_and_the_rest_by_reference() {
        assert!(fits_inline(&[2 << 20, 3 << 20], "look"));
        assert!(fits_inline(&[], &"x".repeat(1 << 20)));
        assert!(!fits_inline(&[INLINE_FILE_BYTES + 1], "big"));
        assert!(!fits_inline(&[1; INLINE_FILES + 1], "many"));
        assert!(!fits_inline(&[3 << 20, 3 << 20, 3 << 20, 3 << 20], "together"));
        assert!(!fits_inline(&[3 << 20], &"x".repeat(28 << 20)), "with its text");
        // Every message the senders put inline fits one JSON-RPC message.
        let most = [INLINE_TOTAL_BYTES / 4; 4];
        assert!(fits_inline(&most, "t"));
        let files: Vec<_> = most.iter().map(|&n| block("a.bin", &vec![0u8; n as usize])).collect();
        assert!(check_wire(&json!({"prompt": files})).is_ok());
    }

    #[test]
    fn a_message_too_big_for_one_frame_is_refused() {
        // Two 11 MiB files fit below 31 MiB once encoded; the extra 2 MiB metadata pushes the
        // complete request over the transport limit.
        let half = vec![0u8; 11 << 20];
        let mut request = json!({"prompt": [block("a.bin", &half), block("b.bin", &half)]});
        assert!(check_wire(&request).is_ok());
        request["_meta"] = json!({"acpmux": {"promptId": "x".repeat(2 << 20)}});
        let refused = check_wire(&request).unwrap_err();
        assert!(refused.message.contains("31 MiB"), "{refused}");
    }

    #[tokio::test]
    async fn a_held_message_keeps_its_files_until_it_is_dropped_or_its_release_never_ran() {
        let root = std::env::temp_dir().join(format!("acpmux-held-{}", uuid::Uuid::now_v7()));
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        let hub = crate::hub::Hub::new(cfg, store);
        let held = |id: &str| {
            Err(RpcError::new(-32000, "held").with_data(json!({"held": true, "promptId": id})))
        };
        for (id, released) in [("dropped", false), ("released", true)] {
            let (dir, own) = (root.join(id), root.join(format!("{id}-upload")));
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::create_dir_all(&own).unwrap();
            let saved = Saved::new("s", vec![own.clone()]).in_dir(dir.clone());
            saved.settle(&hub, &held(id)).await;
            assert!(dir.is_dir(), "{id}: kept while held");
            assert!(own.is_dir(), "{id}: its own upload kept while held");
            if released {
                // Released, then withdrawn from the queue: its run never came.
                held_released(&hub, "s", id).await;
            } else {
                held_dropped("s", id);
                for _ in 0..100 {
                    if !dir.exists() {
                        break;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                }
            }
            assert!(!dir.exists(), "{id}");
            assert!(!own.exists(), "{id}: its own upload");
        }
        let _ = std::fs::remove_dir_all(root);
    }

    /// A prompt the session took and that then never ran (withdrawn from its queue, or refused
    /// when its turn came) deletes the uploads it named as its own; one that ran keeps them.
    #[tokio::test]
    async fn a_taken_prompt_that_never_ran_leaves_none_of_its_own_uploads() {
        let root = std::env::temp_dir().join(format!("acpmux-owned-{}", uuid::Uuid::now_v7()));
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        let hub = crate::hub::Hub::new(cfg, store);
        let withdrawn = Ok(json!({"_meta": {"acpmux": {"withdrawn": true}}}));
        let refused = Err(RpcError::new(-32000, "refused when its turn came"));
        for (id, queued, answer, kept) in [
            ("withdrawn", true, withdrawn, false),
            ("refused", true, refused, false),
            ("ran", false, Ok(json!({"stopReason": "end_turn"})), true),
        ] {
            let own = root.join(id);
            std::fs::create_dir_all(&own).unwrap();
            let saved = Saved::new("s", vec![own.clone()]);
            let accepted = saved.watch(None).unwrap();
            accepted(json!({"queued": queued, "promptId": id}));
            saved.settle(&hub, &answer).await;
            assert_eq!(own.is_dir(), kept, "{id}");
        }
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn files_of_a_message_dropped_unanswered_are_deleted() {
        let root = std::env::temp_dir().join(format!("acpmux-saved-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&root).unwrap();
        drop(Saved::new("", Vec::new()).in_dir(root.clone()));
        assert!(!root.exists());
    }
}
