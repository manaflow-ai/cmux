//! An iPhone attachment past the old 100 MiB cap reaches the Mac whole (Leo:
//! "Attachments take arbitrarily large files of any type; there is no size
//! cap"). The phone side is the exported link the app calls (`connect_inner`,
//! `open_channel`, `ChannelHandle::send`), sending what `LinkUpload` sends: the
//! `upload` args as strings, then the file read from disk 192 KiB at a time.
//! The Mac side is cmux-mobile-host's real `upload` service.

mod common;

use common::{UploadRig, ask, upload_rig, wait_for_offset};

use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use cmux_mobile_link_ffi::{ChannelMessage, Transport};
use sha2::{Digest, Sha256};

/// `LinkUpload.chunkBytes`.
const CHUNK: usize = 192 << 10;
/// About 150 MB, past the old cap and not a multiple of the chunk.
const SIZE: u64 = (150 << 20) + 12_345;

/// A sparse file of `size` bytes with marked pages at its start, middle and
/// end, so a lost, shifted or zeroed chunk changes the hash.
fn sparse_file(path: &Path, size: u64) {
    let mut file = std::fs::File::create(path).unwrap();
    file.set_len(size).unwrap();
    for (mark, at) in [(0x11_u8, 0), (0x22, size / 2), (0x33, size - 4096)] {
        file.seek(SeekFrom::Start(at)).unwrap();
        file.write_all(&[mark; 4096]).unwrap();
    }
}

fn sha256(path: &Path) -> (u64, String) {
    let mut file = std::fs::File::open(path).unwrap();
    let (mut hasher, mut buffer, mut total) = (Sha256::new(), vec![0_u8; 1 << 20], 0_u64);
    loop {
        let read = file.read(&mut buffer).unwrap();
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        total += read as u64;
    }
    (total, format!("{:x}", hasher.finalize()))
}

async fn upload_past_the_old_cap(transport: Transport) {
    let rig = upload_rig(transport).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("big.bin");
    sparse_file(&source, SIZE);
    let args =
        serde_json::json!({"name": "big.bin", "size": SIZE.to_string(), "cwd": rig.root.to_str().unwrap()});
    let channel = rig.handle.open_channel("upload".into(), args.to_string()).await.expect("open upload");
    // As LinkUpload: one chunk read at a time; a failed send means the Mac
    // answered early, so read its answer.
    let mut file = std::fs::File::open(&source).unwrap();
    let (mut buffer, mut sent) = (vec![0_u8; CHUNK], 0_u64);
    while sent < SIZE {
        let read = file.read(&mut buffer).unwrap();
        assert!(read > 0, "the source ended early");
        if channel.send(buffer[..read].to_vec()).await.is_err() {
            break;
        }
        sent += read as u64;
    }
    let mut reply = Vec::new();
    let code = loop {
        match channel.recv().await {
            ChannelMessage::Data { bytes } => reply.extend(bytes),
            ChannelMessage::Closed { code, .. } => break code,
        }
    };
    let reply: serde_json::Value = serde_json::from_slice(&reply).expect("a JSON reply");
    assert_eq!(code, "eof", "the Mac refused the upload: {reply}");
    assert_eq!(sent, SIZE);
    assert_eq!(reply["size"].as_u64(), Some(SIZE), "{reply}");
    let stored = Path::new(reply["path"].as_str().expect("a path"));
    let folder = stored.parent().unwrap();
    assert_eq!(folder.parent().unwrap(), rig.root.join(".cmux/attachments"), "{stored:?}");
    assert!(folder.file_name().unwrap().to_str().unwrap().starts_with("phone-"), "{stored:?}");
    assert_eq!(stored.file_name().unwrap(), "big.bin");
    assert_eq!(sha256(stored), sha256(&source), "the stored file differs from the phone's");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_upload_past_100_mib_arrives_whole_over_wireguard() {
    upload_past_the_old_cap(Transport::WireGuard).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_upload_past_100_mib_arrives_whole_over_webrtc() {
    upload_past_the_old_cap(Transport::WebRtc).await;
}

/// The bytes of a test upload: no two chunks alike.
fn pattern(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i.wrapping_mul(31) ^ (i >> 8)) as u8).collect()
}

async fn open_upload(rig: &UploadRig, args: serde_json::Value) -> cmux_mobile_link_ffi::ChannelHandle {
    rig.handle.open_channel("upload".into(), args.to_string()).await.expect("open upload")
}

fn args(rig: &UploadRig, id: &str, size: usize, offset: Option<usize>) -> serde_json::Value {
    let mut args = serde_json::json!({
        "name": "clip.mov", "size": size.to_string(), "cwd": rig.root.to_str().unwrap(), "id": id,
    });
    if let Some(offset) = offset {
        args["offset"] = offset.to_string().into();
    }
    args
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_upload_resumes_after_an_early_close() {
    let rig = upload_rig(Transport::WireGuard).await;
    let bytes = pattern(1_000_000);
    // Status before anything: nothing kept.
    let (status, _) = ask(&rig, "upload-status", serde_json::json!({"id": "resume-1"})).await;
    assert_eq!(status["offset"], 0, "{status}");
    // The first channel sends 400 000 bytes and drops.
    let first = open_upload(&rig, args(&rig, "resume-1", bytes.len(), None)).await;
    first.send(bytes[..400_000].to_vec()).await.unwrap();
    first.close("cancel".into(), "link dropped".into()).await;
    wait_for_offset(&rig, "resume-1", 400_000).await;
    // A longer partial than the resume point is cut back to it: resume at 300 000.
    let second = open_upload(&rig, args(&rig, "resume-1", bytes.len(), Some(300_000))).await;
    second.send(bytes[300_000..].to_vec()).await.unwrap();
    let (reply, code) = common::read_to_close(&second).await;
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    assert_eq!(code, "eof", "{reply}");
    assert_eq!(reply["size"], 1_000_000, "{reply}");
    let stored = std::path::PathBuf::from(reply["path"].as_str().unwrap());
    assert_eq!(std::fs::read(&stored).unwrap(), bytes);
    assert_eq!(stored.parent().unwrap().parent().unwrap(), rig.root.join(".cmux/attachments"));
    // The finished id answers its file, so a lost final reply is recoverable.
    let (status, _) = ask(&rig, "upload-status", serde_json::json!({"id": "resume-1"})).await;
    assert_eq!(status["path"], reply["path"], "{status}");
    assert_eq!(status["size"], 1_000_000, "{status}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_resume_that_does_not_match_the_kept_bytes_is_refused() {
    let rig = upload_rig(Transport::WireGuard).await;
    // No partial at all.
    let (reply, code) = ask(&rig, "upload", args(&rig, "mismatch-1", 1000, Some(10))).await;
    assert_eq!(reply["error"], "resume_mismatch", "{reply}");
    assert_eq!(code, "resume_mismatch");
    // A partial of 100 bytes cannot resume at 200.
    let first = open_upload(&rig, args(&rig, "mismatch-2", 1000, None)).await;
    first.send(vec![7; 100]).await.unwrap();
    first.close("cancel".into(), String::new()).await;
    wait_for_offset(&rig, "mismatch-2", 100).await;
    let (reply, _) = ask(&rig, "upload", args(&rig, "mismatch-2", 1000, Some(200))).await;
    assert_eq!(reply["error"], "resume_mismatch", "{reply}");
    // The refusal keeps what was there.
    wait_for_offset(&rig, "mismatch-2", 100).await;
    // An offset without an id, and a bad id, are bad requests.
    let (reply, _) = ask(
        &rig,
        "upload",
        serde_json::json!({"name": "a", "size": "5", "offset": "2", "cwd": rig.root.to_str().unwrap()}),
    )
    .await;
    assert_eq!(reply["error"], "bad_request", "{reply}");
    for id in ["", "../x", "a b", &"a".repeat(65)] {
        let (reply, _) = ask(&rig, "upload-status", serde_json::json!({"id": id})).await;
        assert_eq!(reply["error"], "bad_request", "{id}: {reply}");
        let (reply, _) = ask(&rig, "upload", args(&rig, id, 5, None)).await;
        assert_eq!(reply["error"], "bad_request", "{id}: {reply}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_upload_without_an_id_keeps_nothing() {
    let rig = upload_rig(Transport::WireGuard).await;
    let channel = open_upload(
        &rig,
        serde_json::json!({"name": "a.bin", "size": "100", "cwd": rig.root.to_str().unwrap()}),
    )
    .await;
    channel.send(vec![1; 40]).await.unwrap();
    channel.close("cancel".into(), String::new()).await;
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let folder = rig.root.join(".cmux/attachments");
    let files: Vec<_> = walk(&folder);
    assert!(files.is_empty(), "left behind: {files:?}");
}

fn walk(dir: &Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() {
            out.extend(walk(&path));
        } else {
            out.push(path);
        }
    }
    out
}

/// 100 MB over the link, with the Mac's per-phase timings (its `upload` log line, on stderr) and
/// the phone-side throughput. Run `cargo test --release -p cmux-mobile-link-ffi --test upload
/// a_100_mb -- --nocapture` for the numbers.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_100_mb_upload_prints_its_timings() {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter("cmux_mobile_host::services=info")
        .try_init();
    for transport in [Transport::WireGuard, Transport::WebRtc] {
        let rig = upload_rig(transport).await;
        let size: usize = 100 << 20;
        let chunk = pattern(CHUNK);
        let mut args = args(&rig, "timing-100mb", size, None);
        args["name"] = "video.mov".into();
        let started = std::time::Instant::now();
        let channel = open_upload(&rig, args).await;
        let opened = started.elapsed();
        let (mut sent, mut hasher) = (0_usize, Sha256::new());
        while sent < size {
            let n = CHUNK.min(size - sent);
            hasher.update(&chunk[..n]);
            channel.send(chunk[..n].to_vec()).await.unwrap();
            sent += n;
        }
        let sent_at = started.elapsed();
        let (reply, code) = common::read_to_close(&channel).await;
        let total = started.elapsed();
        let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
        assert_eq!(code, "eof", "{reply}");
        let stored = Path::new(reply["path"].as_str().unwrap());
        assert_eq!(sha256(stored).1, format!("{:x}", hasher.finalize()));
        eprintln!(
            "100 MB over {transport:?}: open {:?}, last chunk sent at {:?}, reply at {:?}, {:.1} MB/s end to end",
            opened,
            sent_at,
            total,
            size as f64 / 1_048_576.0 / total.as_secs_f64()
        );
    }
}
