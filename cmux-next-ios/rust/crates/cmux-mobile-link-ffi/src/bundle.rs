//! Attachments and file opens over the Mac's `bundle` service (PROTOCOL.md "bundle", RFD 0142 R7):
//! the file moves as sealed content-defined chunks, and only the chunks the far end lacks cross, so a
//! re-sent attachment or a re-opened file costs one round trip and its manifest.
//!
//! The phone's chunks live in `store_dir` (one folder per Mac, in the app's Caches): `chunks/` holds
//! ciphertext only, `pair-key` the Mac's bundle secret for this phone, kept so the next upload offers
//! at once instead of waiting for the key. A Mac without `bundle` (an older hostd answers
//! `unknown_service`) or a file past [`PHONE_MAX_BUNDLE_BYTES`] goes the old way (`upload`,
//! `file`), and the link remembers the refusal.
//!
//! Every wait on the Mac is bounded ([`PutBounds`]): a Mac that stops answering ends the attempt with
//! [`PutError::TimedOut`] instead of holding the send forever. The attachment engine
//! (`attachment_upload.rs`) runs [`put_bounded`] inside its abortable task with its own `Timings`, so a
//! cancel returns at once and a bound hit is a retry; the Mac keeps the chunks it already stored, so a
//! retried put sends only the missing ones.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use cmux_mobile_link::bundle_link::cmux_bundle::store::{DirStore, MemStore, Store};
use cmux_mobile_link::bundle_link::cmux_bundle::sync::{BATCH_BYTES, Receiver, Sender};
use cmux_mobile_link::bundle_link::cmux_bundle::{self, ChunkId};
use cmux_mobile_link::bundle_link::cmux_bundle::{Kind, PairKey};
use cmux_mobile_link::bundle_link::{self, MessageReader, Read};
use cmux_mobile_link::link::ChannelSender;
use cmux_mobile_link::{ChannelEvent, Lane, Link};

use crate::{CmuxMobileError, LinkHandle, on_runtime};

/// One file moved: where it landed and what crossed the link.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileTransfer {
    /// The upload: the file's path on the Mac (the `upload` reply's). The open: `dest`.
    pub path: String,
    /// The file's size.
    pub size: u64,
    /// Whether it went over `bundle` (false: the old `upload` / `file`).
    pub bundle: bool,
    /// Channel payload bytes the phone sent.
    pub sent_bytes: u64,
    /// Channel payload bytes the phone received.
    pub received_bytes: u64,
}

/// The largest file the phone sends over `bundle`; a larger one goes `upload` (the engine's resumable
/// path, which streams 192 KiB at a time). The phone holds the whole file in memory to chunk it
/// (`Manifest::build` takes a slice; the chunks then stream one ~1 MiB batch at a time, never all at
/// once), and iOS ends an app that grows too far (jetsam: a few hundred MiB on older iPhones, far
/// less for an extension). 64 MiB keeps that peak near 65 MiB, covers photos, screenshots and short
/// clips (`video_plan` sends originals up to 25 MiB as they are), and is a quarter of the protocol's
/// 256 MiB ([`bundle_link::MAX_BUNDLE_BYTES`], which the Mac enforces with `too_large`).
pub const PHONE_MAX_BUNDLE_BYTES: u64 = 64 << 20;

/// Every wait of a bundle put on the Mac. The engine passes its `Timings`; [`Default`] is theirs.
#[derive(Debug, Clone)]
pub struct PutBounds {
    /// Opening the channel.
    pub open: Duration,
    /// The Mac's key, and its want after the offer.
    pub first: Duration,
    /// One message's send (a Mac that stops reading fills the channel's queue).
    pub stall: Duration,
    /// The Mac's `{path, size}` after the last chunk.
    pub final_answer: Duration,
}

impl Default for PutBounds {
    fn default() -> Self {
        Self {
            open: Duration::from_secs(15),
            first: Duration::from_secs(10),
            stall: Duration::from_secs(30),
            final_answer: Duration::from_secs(60),
        }
    }
}

/// What a bounded put reports as it goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PutEvent {
    /// `wire`: channel bytes sent so far this attempt. `covered`: bytes of the file the Mac already
    /// held plus those sent so far this attempt (never more than the file).
    Sent { wire: u64, covered: u64 },
    /// Every chunk is sent; waiting for the Mac's `{path, size}`.
    Finishing,
}

/// Why a bounded put stopped without a result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PutError {
    /// A wait on the Mac passed its bound (named).
    TimedOut(&'static str),
    /// The link or the channel broke.
    Transport(String),
    /// The Mac refused or closed the channel with `code`.
    Refused { code: String, message: String },
    /// The phone could not read the file or its chunk store.
    Local(String),
}

impl From<PutError> for CmuxMobileError {
    fn from(error: PutError) -> Self {
        match error {
            PutError::TimedOut(what) => {
                CmuxMobileError::Transport { message: format!("the Mac did not answer in time ({what})") }
            }
            PutError::Transport(message) | PutError::Local(message) => CmuxMobileError::Transport { message },
            PutError::Refused { code, message } => CmuxMobileError::Refused { code, message },
        }
    }
}

fn local(error: impl std::fmt::Display) -> PutError {
    PutError::Local(error.to_string())
}

/// How the bundle path ended. `Fallback`: it gave up before anything was published, so the file goes
/// the old way; `true` when the Mac has no `bundle` at all (remembered for the link).
pub enum Outcome {
    Done(FileTransfer),
    Fallback(bool),
}

fn io(error: impl std::fmt::Display) -> CmuxMobileError {
    CmuxMobileError::Transport { message: error.to_string() }
}

fn refused(code: &str, message: &str) -> CmuxMobileError {
    CmuxMobileError::Refused { code: code.into(), message: message.into() }
}

fn transport(error: impl std::fmt::Display) -> PutError {
    PutError::Transport(error.to_string())
}

/// A JSON message (`{"error","message"}` from the Mac) as a refusal; `None` for any other message.
fn json_error(msg: &[u8]) -> Option<(String, String)> {
    if msg.first() != Some(&b'{') {
        return None;
    }
    let value: serde_json::Value = serde_json::from_slice(msg).ok()?;
    let code = value.get("error")?.as_str()?.to_owned();
    Some((code, value.get("message").and_then(|m| m.as_str()).unwrap_or_default().to_owned()))
}

struct Wire {
    sender: ChannelSender,
    reader: MessageReader,
    sent: u64,
}

impl Wire {
    /// Opens the `bundle` channel within `bound`. Dropping the wire closes the channel (`dropped`).
    async fn open(link: &Link, args: serde_json::Value, bound: Duration) -> Result<Self, PutError> {
        let channel = match tokio::time::timeout(bound, link.open_on("bundle", args, Lane::Bulk)).await {
            Err(_) => return Err(PutError::TimedOut("open")),
            Ok(opened) => opened.map_err(transport)?,
        };
        let (sender, receiver) = channel.split();
        Ok(Self { sender, reader: MessageReader::new(receiver), sent: 0 })
    }

    /// Sends one message within `stall`; a send to a channel the Mac already closed is left for the
    /// next read to report.
    async fn send(&mut self, msg: &[u8], stall: Duration) -> Result<(), PutError> {
        let frame = bundle_link::frame(msg);
        self.sent += frame.len() as u64;
        match tokio::time::timeout(stall, self.sender.send(frame)).await {
            Err(_) => Err(PutError::TimedOut("send")),
            Ok(_) => Ok(()),
        }
    }

    /// The next message within `bound`; `Ok(Err(unsupported))` when the Mac has no `bundle` (`true`)
    /// or will not bundle this file (`too_large`, `false`).
    async fn next(&mut self, bound: Duration, what: &'static str) -> Result<Result<Vec<u8>, bool>, PutError> {
        let read = match tokio::time::timeout(bound, self.reader.next()).await {
            Err(_) => return Err(PutError::TimedOut(what)),
            Ok(read) => read.map_err(transport)?,
        };
        match read {
            Read::Message(msg) => match json_error(&msg) {
                Some((code, _)) if code == "too_large" => Ok(Err(false)),
                Some((code, message)) => Err(PutError::Refused { code, message }),
                None => Ok(Ok(msg)),
            },
            Read::Closed(info) if info.code == "unknown_service" => Ok(Err(true)),
            Read::Closed(info) if info.code == "too_large" => Ok(Err(false)),
            Read::Closed(info) => Err(PutError::Refused { code: info.code, message: info.reason }),
        }
    }
}

macro_rules! or_fallback {
    ($e:expr) => {
        match $e? {
            Ok(v) => v,
            Err(unsupported) => return Ok(Outcome::Fallback(unsupported)),
        }
    };
}

fn cached_key(store_dir: &Path) -> Option<[u8; 32]> {
    let text = std::fs::read_to_string(store_dir.join("pair-key")).ok()?;
    bundle_link::cmux_bundle::unhex(text.trim()).ok()
}

fn save_key(store_dir: &Path, secret: &[u8; 32]) {
    let _ = std::fs::create_dir_all(store_dir);
    let _ = std::fs::write(store_dir.join("pair-key"), bundle_link::cmux_bundle::hex(secret));
}

/// A store that notes whether any chunk was new to it.
struct Noting<'a> {
    inner: &'a mut DirStore,
    fresh: bool,
}

impl Store for Noting<'_> {
    fn has(&self, id: &ChunkId) -> bool {
        self.inner.has(id)
    }
    fn get(&self, id: &ChunkId) -> cmux_bundle::Result<Option<Vec<u8>>> {
        self.inner.get(id)
    }
    fn put(&mut self, id: &ChunkId, sealed: &[u8]) -> cmux_bundle::Result<()> {
        if !self.inner.has(id) {
            self.fresh = true;
        }
        self.inner.put(id, sealed)
    }
}

/// Chunks and seals `data` into the phone's store (off the async workers). `true` with it when a
/// chunk was new to the phone: content it never sent nor opened, which the Mac most likely lacks too.
async fn build_sender(
    secret: [u8; 32],
    data: Arc<Vec<u8>>,
    chunks: PathBuf,
) -> Result<(Arc<Sender>, bool), PutError> {
    tokio::task::spawn_blocking(move || {
        let mut store = DirStore::new(chunks);
        let mut noting = Noting { inner: &mut store, fresh: false };
        let sender = Sender::new(&PairKey::derive(&secret), Kind::Attachment, &data, &mut noting)?;
        Ok((Arc::new(sender), noting.fresh))
    })
    .await
    .map_err(local)?
    .map_err(|e: cmux_bundle::Error| local(e))
}

/// One attempt's sending side: the wire, the bounds and the progress report.
struct Put<'a> {
    wire: Wire,
    bounds: &'a PutBounds,
    report: &'a mut (dyn FnMut(PutEvent) + Send),
    size: u64,
}

impl Put<'_> {
    fn sent(&mut self, covered: u64) {
        (self.report)(PutEvent::Sent { wire: self.wire.sent, covered: covered.min(self.size) });
    }

    /// Offers `sender`'s bundle; for new content also sends every chunk at once, without waiting for
    /// the Mac's want (it takes any chunk its offer names), so a first send costs no round trip more
    /// than `upload`.
    async fn offer(
        &mut self,
        key: &PairKey,
        sender: &Arc<Sender>,
        fresh: bool,
        chunks: &Path,
    ) -> Result<(), PutError> {
        let offer = sender.offer();
        self.wire.send(&offer, self.bounds.stall).await?;
        if fresh {
            let all = Receiver::on_offer(key, &offer).map_err(local)?.want(&MemStore::default());
            self.send_chunks(sender, &all, chunks).await?;
        }
        Ok(())
    }

    /// Answers `want` one ~[`BATCH_BYTES`] chunks message at a time (read off the async workers), each
    /// send bounded, reporting the file bytes covered after each.
    async fn send_chunks(
        &mut self,
        sender: &Arc<Sender>,
        want: &[u8],
        chunks: &Path,
    ) -> Result<(), PutError> {
        let positions = sender
            .wanted(want)
            .map_err(|e| PutError::Refused { code: "bad_request".into(), message: e.to_string() })?;
        let manifest = &sender.manifest().chunks;
        // The file bytes each distinct chunk stands for (a chunk may repeat).
        let mut covers: HashMap<ChunkId, u64> = HashMap::new();
        for c in manifest {
            *covers.entry(c.id).or_default() += u64::from(c.len);
        }
        let cover = |i: usize| covers.get(&manifest[i].id).copied().unwrap_or(0);
        let wanted: u64 = positions.iter().map(|&i| cover(i)).sum();
        let mut covered = self.size.saturating_sub(wanted);
        self.sent(covered);
        let mut batch: Vec<usize> = Vec::new();
        let mut batch_bytes = 0usize;
        for (n, &i) in positions.iter().enumerate() {
            batch.push(i);
            batch_bytes += manifest[i].len as usize + 64;
            let last = n + 1 == positions.len();
            if !last && batch_bytes + manifest[positions[n + 1]].len as usize + 64 <= BATCH_BYTES {
                continue;
            }
            let (s, dir, b) = (Arc::clone(sender), chunks.to_path_buf(), std::mem::take(&mut batch));
            let (b, msg) = tokio::task::spawn_blocking(move || {
                let msg = s.chunks_message(&b, &DirStore::new(dir));
                (b, msg)
            })
            .await
            .map_err(local)?;
            let msg = msg.map_err(local)?;
            self.wire.send(&msg, self.bounds.stall).await?;
            covered += b.iter().map(|&i| cover(i)).sum::<u64>();
            self.sent(covered);
            batch_bytes = 0;
        }
        Ok(())
    }
}

async fn settle(chunks: PathBuf, ids: Vec<bundle_link::cmux_bundle::ChunkId>) {
    let _ = tokio::task::spawn_blocking(move || {
        bundle_link::touch(&chunks, ids);
        bundle_link::evict(&chunks, bundle_link::PHONE_STORE_CAP);
    })
    .await;
}

/// `bundle` `put` with every wait bounded by `bounds` and progress through `report`; a file past
/// `max_bytes` (or one the Mac calls `too_large`, or a Mac without `bundle`) is `Fallback`.
#[allow(clippy::too_many_arguments)]
pub async fn put_bounded(
    link: &Link,
    path: &Path,
    name: &str,
    cwd: &str,
    store_dir: &Path,
    max_bytes: u64,
    bounds: &PutBounds,
    report: &mut (dyn FnMut(PutEvent) + Send),
) -> Result<Outcome, PutError> {
    let size = tokio::fs::metadata(path).await.map_err(local)?.len();
    if size > max_bytes {
        return Ok(Outcome::Fallback(false));
    }
    let data = Arc::new(tokio::fs::read(path).await.map_err(local)?);
    let size = data.len() as u64;
    if size > max_bytes {
        return Ok(Outcome::Fallback(false));
    }
    let chunks = store_dir.join("chunks");
    let mut args = serde_json::json!({"op": "put", "name": name, "size": size});
    if !cwd.is_empty() {
        args["cwd"] = cwd.into();
    }
    let wire = Wire::open(link, args, bounds.open).await?;
    let mut put = Put { wire, bounds, report, size };
    // With the key from last time the offer goes with the open: one round trip in all.
    let mut offered = None;
    if let Some(secret) = cached_key(store_dir) {
        let (sender, fresh) = build_sender(secret, data.clone(), chunks.clone()).await?;
        put.offer(&PairKey::derive(&secret), &sender, fresh, &chunks).await?;
        offered = Some((secret, sender, fresh));
    }
    let first = or_fallback!(put.wire.next(bounds.first, "the bundle key").await);
    let secret = bundle_link::parse_key_message(&first).ok_or_else(|| PutError::Refused {
        code: "bad_request".into(),
        message: "the Mac sent no bundle key".into(),
    })?;
    let (sender, pushed) = match offered {
        Some((cached, sender, fresh)) if cached == secret => (sender, fresh),
        _ => {
            save_key(store_dir, &secret);
            let (sender, fresh) = build_sender(secret, data.clone(), chunks.clone()).await?;
            put.offer(&PairKey::derive(&secret), &sender, fresh, &chunks).await?;
            (sender, fresh)
        }
    };
    drop(data);
    let want = or_fallback!(put.wire.next(bounds.first, "the want").await);
    if !pushed {
        put.send_chunks(&sender, &want, &chunks).await?;
    }
    (put.report)(PutEvent::Finishing);
    let reply = or_fallback!(put.wire.next(bounds.final_answer, "the final answer").await);
    let reply: serde_json::Value = serde_json::from_slice(&reply).map_err(transport)?;
    let path = reply.get("path").and_then(|p| p.as_str()).ok_or_else(|| transport("no path in the reply"))?;
    put.sent(size);
    let transfer = FileTransfer {
        path: path.to_owned(),
        size,
        bundle: true,
        sent_bytes: put.wire.sent,
        received_bytes: put.wire.reader.received,
    };
    settle(chunks, sender.manifest().chunks.iter().map(|c| c.id).collect()).await;
    Ok(Outcome::Done(transfer))
}

/// [`put_bounded`] with the default bounds, no progress and the phone's cap.
pub async fn upload_bundle(
    link: &Link,
    path: &Path,
    name: &str,
    cwd: &str,
    store_dir: &Path,
) -> Result<Outcome, CmuxMobileError> {
    let mut quiet = |_: PutEvent| {};
    put_bounded(link, path, name, cwd, store_dir, PHONE_MAX_BUNDLE_BYTES, &PutBounds::default(), &mut quiet)
        .await
        .map_err(Into::into)
}

pub async fn open_bundle(
    link: &Link,
    path: &str,
    dest: &Path,
    store_dir: &Path,
) -> Result<Outcome, CmuxMobileError> {
    let chunks = store_dir.join("chunks");
    let bounds = PutBounds::default();
    let mut wire = Wire::open(link, serde_json::json!({"op": "get", "path": path}), bounds.open).await?;
    let first = or_fallback!(wire.next(bounds.first, "the bundle key").await);
    let secret = bundle_link::parse_key_message(&first).ok_or_else(|| io("the Mac sent no bundle key"))?;
    save_key(store_dir, &secret);
    let key = PairKey::derive(&secret);
    let offer = or_fallback!(wire.next(bounds.first, "the offer").await);
    let receiver = Receiver::on_offer(&key, &offer).map_err(io)?;
    let mut store = DirStore::new(&chunks);
    if !receiver.missing(&store).is_empty() {
        wire.send(&receiver.want(&store), bounds.stall).await?;
        let mut done = false;
        while !done {
            let msg = or_fallback!(wire.next(bounds.stall, "the chunks").await);
            if msg.is_empty() {
                return Err(io("the Mac ended the bundle before every chunk"));
            }
            done = receiver.on_chunks(&msg, &mut store).map_err(io)?;
        }
    }
    // Every chunk is here: the Mac's channel can go (it may still send its empty end message).
    wire.sender.close("eof", "").await;
    let (receiver, bytes) = tokio::task::spawn_blocking(move || {
        let bytes = receiver.assemble(&store);
        (receiver, bytes)
    })
    .await
    .map_err(io)?;
    let bytes = bytes.map_err(io)?;
    write_file(dest, &bytes).await?;
    let transfer = FileTransfer {
        path: dest.to_string_lossy().into_owned(),
        size: bytes.len() as u64,
        bundle: true,
        sent_bytes: wire.sent,
        received_bytes: wire.reader.received,
    };
    settle(chunks, receiver.manifest().chunks.iter().map(|c| c.id).collect()).await;
    Ok(Outcome::Done(transfer))
}

async fn write_file(dest: &Path, bytes: &[u8]) -> Result<(), CmuxMobileError> {
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent).await.map_err(io)?;
    }
    let part = dest.with_extension(format!("{}.part", uuid::Uuid::new_v4()));
    tokio::fs::write(&part, bytes).await.map_err(io)?;
    tokio::fs::rename(&part, dest).await.map_err(|e| {
        let _ = std::fs::remove_file(&part);
        io(e)
    })
}

/// The old `upload`: the args, then the file's bytes, then the Mac's `{path, size}`.
pub async fn upload_plain(
    link: &Link,
    path: &Path,
    name: &str,
    cwd: &str,
) -> Result<FileTransfer, CmuxMobileError> {
    use tokio::io::AsyncReadExt;
    let size = std::fs::metadata(path).map_err(io)?.len();
    let mut args = serde_json::json!({"name": name, "size": size.to_string()});
    if !cwd.is_empty() {
        args["cwd"] = cwd.into();
    }
    let channel = link.open_on("upload", args, Lane::Bulk).await?;
    let (sender, mut receiver) = channel.split();
    let mut file = tokio::fs::File::open(path).await.map_err(io)?;
    let (mut buffer, mut sent) = (vec![0u8; 192 << 10], 0u64);
    loop {
        let read = file.read(&mut buffer).await.map_err(io)?;
        if read == 0 || sender.send(buffer[..read].to_vec().into()).await.is_err() {
            break;
        }
        sent += read as u64;
    }
    let (mut reply, mut received) = (Vec::new(), 0u64);
    let code = loop {
        match receiver.recv().await {
            Some(ChannelEvent::Data(bytes)) => {
                received += bytes.len() as u64;
                reply.extend_from_slice(&bytes);
            }
            Some(ChannelEvent::Closed(info)) => break info.code,
            None => break "closed".into(),
        }
    };
    let value: serde_json::Value = serde_json::from_slice(&reply).unwrap_or_default();
    if code != "eof" {
        let message = value.get("message").and_then(|m| m.as_str()).unwrap_or_default();
        return Err(refused(&code, message));
    }
    let path = value.get("path").and_then(|p| p.as_str()).ok_or_else(|| io("no path in the reply"))?;
    Ok(FileTransfer {
        path: path.to_owned(),
        size,
        bundle: false,
        sent_bytes: sent,
        received_bytes: received,
    })
}

/// The old `file`: the file's bytes until the Mac closes with `eof`.
pub async fn open_plain(link: &Link, path: &str, dest: &Path) -> Result<FileTransfer, CmuxMobileError> {
    let channel = link.open_on("file", serde_json::json!({"path": path}), Lane::Bulk).await?;
    let (_sender, mut receiver) = channel.split();
    let mut bytes = Vec::new();
    loop {
        match receiver.recv().await {
            Some(ChannelEvent::Data(data)) => bytes.extend_from_slice(&data),
            Some(ChannelEvent::Closed(info)) if info.code == "eof" => break,
            Some(ChannelEvent::Closed(info)) => return Err(refused(&info.code, &info.reason)),
            None => return Err(io("the link closed")),
        }
    }
    write_file(dest, &bytes).await?;
    let size = bytes.len() as u64;
    Ok(FileTransfer {
        path: dest.to_string_lossy().into_owned(),
        size,
        bundle: false,
        sent_bytes: 0,
        received_bytes: size,
    })
}

#[uniffi::export]
impl LinkHandle {
    /// Send the phone's file at `path` to the Mac as attachment `name` (into `cwd`'s attachments
    /// folder when given, as `upload`), over `bundle` when the Mac has it: a file the Mac already
    /// holds costs one round trip and its manifest. `store_dir` is this Mac's folder in the app's
    /// Caches. Falls back to `upload` on an older Mac.
    pub async fn upload_file_bundle(
        &self,
        path: String,
        name: String,
        cwd: String,
        store_dir: String,
    ) -> Result<FileTransfer, CmuxMobileError> {
        let link = self.link.clone();
        let skip = self.bundle_refused.load(Ordering::Acquire);
        let (transfer, unsupported) = on_runtime(async move {
            let (path, store_dir) = (PathBuf::from(path), PathBuf::from(store_dir));
            let unsupported = if skip {
                true
            } else {
                match upload_bundle(&link, &path, &name, &cwd, &store_dir).await? {
                    Outcome::Done(transfer) => return Ok::<_, CmuxMobileError>((transfer, false)),
                    Outcome::Fallback(unsupported) => unsupported,
                }
            };
            Ok((upload_plain(&link, &path, &name, &cwd).await?, unsupported))
        })
        .await?;
        if unsupported {
            self.bundle_refused.store(true, Ordering::Release);
        }
        Ok(transfer)
    }

    /// Open the Mac's file at `path` into `dest` on the phone, over `bundle` when the Mac has it:
    /// chunks the phone already holds (it sent the file, or opened it before) do not cross again.
    /// Falls back to `file` on an older Mac.
    pub async fn open_file_bundle(
        &self,
        path: String,
        dest: String,
        store_dir: String,
    ) -> Result<FileTransfer, CmuxMobileError> {
        let link = self.link.clone();
        let skip = self.bundle_refused.load(Ordering::Acquire);
        let (transfer, unsupported) = on_runtime(async move {
            let (dest, store_dir) = (PathBuf::from(dest), PathBuf::from(store_dir));
            let unsupported = if skip {
                true
            } else {
                match open_bundle(&link, &path, &dest, &store_dir).await? {
                    Outcome::Done(transfer) => return Ok::<_, CmuxMobileError>((transfer, false)),
                    Outcome::Fallback(unsupported) => unsupported,
                }
            };
            Ok((open_plain(&link, &path, &dest).await?, unsupported))
        })
        .await?;
        if unsupported {
            self.bundle_refused.store(true, Ordering::Release);
        }
        Ok(transfer)
    }
}
