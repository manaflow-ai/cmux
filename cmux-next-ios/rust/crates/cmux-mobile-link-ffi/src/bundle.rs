//! Attachments and file opens over the Mac's `bundle` service (PROTOCOL.md "bundle", RFD 0142 R7):
//! the file moves as sealed content-defined chunks, and only the chunks the far end lacks cross, so a
//! re-sent attachment or a re-opened file costs one round trip and its manifest.
//!
//! The phone's chunks live in `store_dir` (one folder per Mac, in the app's Caches): `chunks/` holds
//! ciphertext only, `pair-key` the Mac's bundle secret for this phone, kept so the next upload offers
//! at once instead of waiting for the key. A Mac without `bundle` (an older hostd answers
//! `unknown_service`) or a file past [`bundle_link::MAX_BUNDLE_BYTES`] goes the old way (`upload`,
//! `file`), and the link remembers the refusal.

use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;

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
    async fn open(link: &Link, args: serde_json::Value) -> Result<Self, CmuxMobileError> {
        let channel = link.open_on("bundle", args, Lane::Bulk).await?;
        let (sender, receiver) = channel.split();
        Ok(Self { sender, reader: MessageReader::new(receiver), sent: 0 })
    }

    /// Sends one message; a send to a channel the Mac already closed is left for the next read to report.
    async fn send(&mut self, msg: &[u8]) {
        let frame = bundle_link::frame(msg);
        self.sent += frame.len() as u64;
        let _ = self.sender.send(frame).await;
    }

    /// The next message; `Ok(Err(unsupported))` when the Mac has no `bundle` (`true`) or will not
    /// bundle this file (`too_large`, `false`).
    async fn next(&mut self) -> Result<Result<Vec<u8>, bool>, CmuxMobileError> {
        match self.reader.next().await.map_err(io)? {
            Read::Message(msg) => match json_error(&msg) {
                Some((code, _)) if code == "too_large" => Ok(Err(false)),
                Some((code, message)) => Err(refused(&code, &message)),
                None => Ok(Ok(msg)),
            },
            Read::Closed(info) if info.code == "unknown_service" => Ok(Err(true)),
            Read::Closed(info) if info.code == "too_large" => Ok(Err(false)),
            Read::Closed(info) => Err(refused(&info.code, &info.reason)),
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
    data: std::sync::Arc<Vec<u8>>,
    chunks: PathBuf,
) -> Result<(Sender, bool), CmuxMobileError> {
    tokio::task::spawn_blocking(move || {
        let mut store = DirStore::new(chunks);
        let mut noting = Noting { inner: &mut store, fresh: false };
        let sender = Sender::new(&PairKey::derive(&secret), Kind::Attachment, &data, &mut noting)?;
        Ok((sender, noting.fresh))
    })
    .await
    .map_err(io)?
    .map_err(|e: cmux_bundle::Error| io(e))
}

/// Offers `sender`'s bundle; for new content also sends every chunk at once, without waiting for
/// the Mac's want (it takes any chunk its offer names), so a first send costs no round trip more
/// than `upload`.
async fn offer(
    wire: &mut Wire,
    key: &PairKey,
    sender: &Sender,
    fresh: bool,
    chunks: &Path,
) -> Result<(), CmuxMobileError> {
    let offer = sender.offer();
    wire.send(&offer).await;
    if fresh {
        let all = Receiver::on_offer(key, &offer).map_err(io)?.want(&MemStore::default());
        for msg in sender.on_want(&all, &DirStore::new(chunks), BATCH_BYTES).map_err(io)? {
            wire.send(&msg).await;
        }
    }
    Ok(())
}

async fn settle(chunks: PathBuf, ids: Vec<bundle_link::cmux_bundle::ChunkId>) {
    let _ = tokio::task::spawn_blocking(move || {
        bundle_link::touch(&chunks, ids);
        bundle_link::evict(&chunks, bundle_link::PHONE_STORE_CAP);
    })
    .await;
}

pub async fn upload_bundle(
    link: &Link,
    path: &Path,
    name: &str,
    cwd: &str,
    store_dir: &Path,
) -> Result<Outcome, CmuxMobileError> {
    let size = std::fs::metadata(path).map_err(io)?.len();
    if size > bundle_link::MAX_BUNDLE_BYTES {
        return Ok(Outcome::Fallback(false));
    }
    let data = std::sync::Arc::new(tokio::fs::read(path).await.map_err(io)?);
    let chunks = store_dir.join("chunks");
    let mut args = serde_json::json!({"op": "put", "name": name, "size": size});
    if !cwd.is_empty() {
        args["cwd"] = cwd.into();
    }
    let mut wire = Wire::open(link, args).await?;
    // With the key from last time the offer goes with the open: one round trip in all.
    let mut offered = None;
    if let Some(secret) = cached_key(store_dir) {
        let (sender, fresh) = build_sender(secret, data.clone(), chunks.clone()).await?;
        offer(&mut wire, &PairKey::derive(&secret), &sender, fresh, &chunks).await?;
        offered = Some((secret, sender, fresh));
    }
    let first = or_fallback!(wire.next().await);
    let secret = bundle_link::parse_key_message(&first).ok_or_else(|| io("the Mac sent no bundle key"))?;
    let (sender, pushed) = match offered {
        Some((cached, sender, fresh)) if cached == secret => (sender, fresh),
        _ => {
            save_key(store_dir, &secret);
            let (sender, fresh) = build_sender(secret, data.clone(), chunks.clone()).await?;
            offer(&mut wire, &PairKey::derive(&secret), &sender, fresh, &chunks).await?;
            (sender, fresh)
        }
    };
    let want = or_fallback!(wire.next().await);
    if !pushed {
        let store = DirStore::new(&chunks);
        for msg in sender.on_want(&want, &store, BATCH_BYTES).map_err(io)? {
            wire.send(&msg).await;
        }
    }
    let reply = or_fallback!(wire.next().await);
    let reply: serde_json::Value = serde_json::from_slice(&reply).map_err(io)?;
    let path = reply.get("path").and_then(|p| p.as_str()).ok_or_else(|| io("no path in the reply"))?;
    let transfer = FileTransfer {
        path: path.to_owned(),
        size,
        bundle: true,
        sent_bytes: wire.sent,
        received_bytes: wire.reader.received,
    };
    settle(chunks, sender.manifest().chunks.iter().map(|c| c.id).collect()).await;
    Ok(Outcome::Done(transfer))
}

pub async fn open_bundle(
    link: &Link,
    path: &str,
    dest: &Path,
    store_dir: &Path,
) -> Result<Outcome, CmuxMobileError> {
    let chunks = store_dir.join("chunks");
    let mut wire = Wire::open(link, serde_json::json!({"op": "get", "path": path})).await?;
    let first = or_fallback!(wire.next().await);
    let secret = bundle_link::parse_key_message(&first).ok_or_else(|| io("the Mac sent no bundle key"))?;
    save_key(store_dir, &secret);
    let key = PairKey::derive(&secret);
    let offer = or_fallback!(wire.next().await);
    let receiver = Receiver::on_offer(&key, &offer).map_err(io)?;
    let mut store = DirStore::new(&chunks);
    if !receiver.missing(&store).is_empty() {
        wire.send(&receiver.want(&store)).await;
        let mut done = false;
        while !done {
            let msg = or_fallback!(wire.next().await);
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
