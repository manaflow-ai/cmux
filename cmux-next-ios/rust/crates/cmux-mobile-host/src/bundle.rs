//! `bundle`: an attachment upload (`put`) or a file open (`get`) as sealed, content-defined chunks
//! (RFD 0142 R7, `cmux_bundle`), so a file the far end already holds costs one round trip and its
//! manifest instead of its bytes (PROTOCOL.md "bundle"). Messages are length-prefixed
//! (`cmux_mobile_link::bundle_link`).
//!
//! The first message from the Mac is the pair's bundle secret (`{"v":1,"key":"<hex>"}`), derived from
//! this Mac's identity and the phone's device id, so the same phone always gets the same key and its
//! chunk ids stay valid across links. The link is authenticated and encrypted already; the key only
//! names and seals chunks at rest (a relay cache never sees it).
//!
//! - `put` `{name, size, cwd?}` (as `upload`): the phone offers the manifest, this Mac answers with
//!   the chunks it lacks, the phone sends them without waiting, and the file is published exactly as
//!   `upload` publishes one, with the same `{path, size}` reply. A phone that held a stale key may
//!   offer once more after reading the key.
//! - `get` `{path}` (as `file`, the same roots and open checks): this Mac offers, the phone answers
//!   with what it lacks, this Mac sends those chunks and then an empty message.
//!
//! Chunks live under `<uploads>/bundle-chunks` (ciphertext only), capped at
//! [`bundle_link::HOST_STORE_CAP`], oldest first out.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use cmux_mobile_link::bundle_link::cmux_bundle::store::DirStore;
use cmux_mobile_link::bundle_link::cmux_bundle::sync::{BATCH_BYTES, Receiver, Sender};
use cmux_mobile_link::bundle_link::cmux_bundle::{self, Kind, PairKey};
use cmux_mobile_link::bundle_link::{self, MessageReader, Read};
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use serde_json::Value;
use tokio::io::AsyncReadExt;

use crate::config::ServiceConfig;
use crate::services::{Peer, Refusal};

/// A sync message's type byte for chunks (`cmux_bundle::sync`: `[1][type][root]`).
const CHUNKS: u8 = 3;
/// The most chunks messages a bundle sends: [`bundle_link::MAX_BUNDLE_BYTES`] in batches of
/// [`BATCH_BYTES`], with room for the batches' overshoot.
const MAX_SKIPPED: usize = 2 * (bundle_link::MAX_BUNDLE_BYTES as usize / BATCH_BYTES) + 2;

/// The derivation context of a phone's bundle secret.
const SECRET_CONTEXT: &str = "cmux-bundle v1 pair secret";

/// The `bundle` service.
pub async fn serve(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let result = match args.get("op").and_then(Value::as_str) {
        Some("put") => put(config, peer, args, sender, receiver).await,
        Some("get") => get(config, peer, args, sender, receiver).await,
        _ => Err(Refusal::new("bad_request", "op must be put or get")),
    };
    if let Err(refusal) = &result {
        let reply = serde_json::json!({"error": refusal.code, "message": refusal.reason}).to_string();
        let _ = sender.send(bundle_link::frame(reply.as_bytes())).await;
    }
    result
}

/// The bundle secret of `peer` on this Mac: `blake3::derive_key(SECRET_CONTEXT, material || phone)`,
/// where the material is this Mac's box key (itself derived from its identity key, `seal::box_key`)
/// or, for a hostd running without the app's identity, a secret of this process.
pub fn pair_secret(config: &ServiceConfig, peer: &Peer) -> [u8; 32] {
    let identity = config
        .pairing
        .as_ref()
        .and_then(|pairing| pairing.identity.borrow().as_ref().map(|id| id.box_secret().to_bytes().to_vec()));
    let mut input = identity.unwrap_or_else(|| process_secret().to_vec());
    input.extend_from_slice(peer.device_id.as_bytes());
    blake3::derive_key(SECRET_CONTEXT, &input)
}

fn process_secret() -> &'static [u8; 32] {
    static SECRET: OnceLock<[u8; 32]> = OnceLock::new();
    SECRET.get_or_init(|| {
        crate::seal::random_secret()
            .map(|key| key.to_bytes().into())
            .unwrap_or_else(|_| *blake3::hash(uuid::Uuid::new_v4().as_bytes()).as_bytes())
    })
}

fn store_root(config: &ServiceConfig) -> Result<PathBuf, Refusal> {
    crate::services::create_private_dir(&config.uploads_dir)?;
    let root = config.uploads_dir.join("bundle-chunks");
    crate::services::create_private_dir(&root)?;
    Ok(root)
}

fn bad(error: impl std::fmt::Display) -> Refusal {
    Refusal::new("bad_request", error.to_string())
}

async fn next_message(reader: &mut MessageReader) -> Result<Vec<u8>, Refusal> {
    match reader.next().await.map_err(bad)? {
        Read::Message(msg) => Ok(msg),
        Read::Closed(_) => Err(Refusal::new("bad_request", "the bundle ended early")),
    }
}

async fn send(sender: &ChannelSender, msg: &[u8]) -> Result<(), Refusal> {
    sender.send(bundle_link::frame(msg)).await.map_err(|e| Refusal::new("closed", e.to_string()))
}

/// After a bundle: its chunks are fresh, and the store is trimmed to its cap (off the async workers).
async fn settle(root: PathBuf, ids: Vec<cmux_bundle::ChunkId>) {
    let _ = tokio::task::spawn_blocking(move || {
        bundle_link::touch(&root, ids);
        bundle_link::evict(&root, bundle_link::HOST_STORE_CAP);
    })
    .await;
}

async fn put(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let (name, size, folder) = crate::services::upload_target(config, peer, args).await?;
    if size > bundle_link::MAX_BUNDLE_BYTES {
        return Err(Refusal::new("too_large", "larger than a bundle moves; use upload"));
    }
    let root = store_root(config)?;
    let mut store = DirStore::new(&root);
    let secret = pair_secret(config, peer);
    let key = PairKey::derive(&secret);
    send(sender, &bundle_link::key_message(&secret)).await?;
    let mut reader = MessageReader::new(receiver);
    // A phone with a stale cached key offers under it (and may send that bundle's chunks at once)
    // before it reads ours, then offers again: past one offer that does not open, its chunks
    // messages are skipped, up to the most a bundle has.
    let mut stale = false;
    let mut skipped = 0usize;
    let incoming = loop {
        let msg = next_message(&mut reader).await?;
        if stale && msg.get(1) == Some(&CHUNKS) {
            skipped += 1;
            if skipped > MAX_SKIPPED {
                return Err(Refusal::new("bad_request", "too many chunks under a stale key"));
            }
            continue;
        }
        match Receiver::on_offer(&key, &msg) {
            Ok(r) => break r,
            Err(cmux_bundle::Error::Seal) if !stale => stale = true,
            Err(e) => return Err(bad(e)),
        }
    };
    if incoming.manifest().total != size {
        return Err(Refusal::new("bad_request", "the offer's size is not the declared size"));
    }
    send(sender, &incoming.want(&store)).await?;
    let mut done = incoming.missing(&store).is_empty();
    while !done {
        let msg = next_message(&mut reader).await?;
        done = incoming.on_chunks(&msg, &mut store).map_err(bad)?;
    }
    let (incoming, bytes) = tokio::task::spawn_blocking(move || {
        let bytes = incoming.assemble(&store);
        (incoming, bytes)
    })
    .await
    .map_err(|e| Refusal::new("io", e.to_string()))?;
    let bytes = bytes.map_err(bad)?;
    let path = publish(&folder, &name, &bytes).await?;
    tracing::info!(size, received = reader.received, phone = peer.device_id, "bundle upload saved");
    let reply = serde_json::json!({"path": path.to_string_lossy(), "size": size}).to_string();
    let _ = sender.send(bundle_link::frame(reply.as_bytes())).await;
    settle(root, incoming.manifest().chunks.iter().map(|c| c.id).collect()).await;
    Ok(())
}

/// Writes `bytes` to a new part file of `folder` and links it in under `name` (as `upload` does).
async fn publish(folder: &Path, name: &str, bytes: &[u8]) -> Result<PathBuf, Refusal> {
    use tokio::io::AsyncWriteExt;
    let part = folder.join(format!(".{}.part", uuid::Uuid::new_v4()));
    let written = async {
        let mut file = tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&part)
            .await
            .map_err(|e| Refusal::new("io", format!("cannot create the upload: {e}")))?;
        file.write_all(bytes).await.map_err(|e| Refusal::new("io", e.to_string()))?;
        file.sync_all().await.map_err(|e| Refusal::new("io", e.to_string()))
    }
    .await;
    if let Err(refusal) = written {
        let _ = std::fs::remove_file(&part);
        return Err(refusal);
    }
    crate::services::publish_upload(folder, name, &part).inspect_err(|_| {
        let _ = std::fs::remove_file(&part);
    })
}

async fn get(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let (file, metadata) = crate::services::open_shared_file(config, args).await?;
    if metadata.len() > bundle_link::MAX_BUNDLE_BYTES {
        return Err(Refusal::new("too_large", "larger than a bundle moves; use file"));
    }
    let mut data = Vec::with_capacity(metadata.len() as usize);
    file.take(metadata.len()).read_to_end(&mut data).await.map_err(|e| Refusal::new("io", e.to_string()))?;
    let root = store_root(config)?;
    let secret = pair_secret(config, peer);
    send(sender, &bundle_link::key_message(&secret)).await?;
    let (outgoing, store) = tokio::task::spawn_blocking(move || {
        let mut store = DirStore::new(&root);
        Sender::new(&PairKey::derive(&secret), Kind::Attachment, &data, &mut store).map(|s| (s, store))
    })
    .await
    .map_err(|e| Refusal::new("io", e.to_string()))?
    .map_err(|e| Refusal::new("io", e.to_string()))?;
    send(sender, &outgoing.offer()).await?;
    let mut reader = MessageReader::new(receiver);
    let want = match reader.next().await.map_err(bad)? {
        Read::Message(msg) => msg,
        // The phone held every chunk and went: nothing more to send.
        Read::Closed(_) => return Ok(()),
    };
    for msg in outgoing.on_want(&want, &store, BATCH_BYTES).map_err(bad)? {
        send(sender, &msg).await?;
    }
    // The phone may close as soon as it holds every chunk, before this end message.
    let _ = sender.send(bundle_link::frame(&[])).await;
    tracing::info!(size = metadata.len(), phone = peer.device_id, "bundle file sent");
    settle(store_root(config)?, outgoing.manifest().chunks.iter().map(|c| c.id).collect()).await;
    Ok(())
}
