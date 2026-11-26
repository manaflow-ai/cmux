//! Attachments and file opens over `bundle` (RFD 0142 R7), against a real hostd on FakeSignaling, in
//! lockstep with the old services (Leo, 2026-11-24: "of course acpmux/cmux protocols need to be able to
//! work in lockstep with these and improve ever further"):
//! (a) a re-sent attachment moves under 4 KB and lands identical;
//! (b) a new phone against a Mac without `bundle` falls back to `upload`;
//! (c) an old phone's `upload` still works on the new Mac;
//! (d) opening a file whose chunks the phone holds moves under 4 KB;
//! (e) a forged or oversized message is refused.
//!
//! Each prints a `scoreboard:` line (bytes and ms) for the PR's rows.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::bundle_link;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link_ffi::{ChannelMessage, ConnectRequest, LinkHandle, Transport, WarmPool};
use sha2::{Digest, Sha256};

struct Rig {
    _server: FakeSignaling,
    _dirs: tempfile::TempDir,
    root: PathBuf,
    handle: Arc<LinkHandle>,
}

/// A real hostd and the phone's link to it.
async fn rig() -> Rig {
    rig_with(false).await
}

/// With `old_host`, the Mac is a hostd from before `bundle`: it answers sessions as hostd does
/// (`dial::answer`), refuses `bundle` with `unknown_service`, and serves `upload` as that hostd did.
async fn rig_with(old_host: bool) -> Rig {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let dirs = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dirs.path()).unwrap().join("work");
    std::fs::create_dir_all(&root).unwrap();
    let services = ServiceConfig {
        tui_socket_dir: dirs.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![root.clone()],
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        browser: Default::default(),
        surface: Default::default(),
        chief_socket: None,
        agent_tab_host: None,
        uploads_dir: dirs.path().join("uploads"),
        pairing: None,
        viewport_sync: None,
    };
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    if old_host {
        tokio::spawn(serve_old_host(mac, dirs.path().join("old-uploads")));
    } else {
        tokio::spawn(serve_signaling(
            mac,
            AnswerContext {
                owner_user_id: "alice".into(),
                services: Arc::new(services),
                ice: IceSource::Fixed(Vec::new()),
                include_loopback: true,
                exclude_cgnat: false,
                mailbox: None,
                session_exposure: None,
            },
        ));
    }
    // A pool of its own (as tests/ffi.rs), so no test dials on another test's warm socket.
    let handle = WarmPool::new()
        .connect(
            ConnectRequest {
                base_url: server.base_url.clone(),
                token: "user:alice".into(),
                team_id: "team".into(),
                device_id: uuid::Uuid::new_v4().to_string(),
                mac_device_id: mac_id,
                transport: Transport::WireGuard,
                include_loopback: true,
                relay_only: false,
                block_udp: false,
                proxy_only: false,
                drop_wireguard: false,
                video_lane: false,
                webrtc_media: false,
                ultra: cmux_mobile_link::UltraSetting::Off,
                force_relay: false,
            },
            None,
        )
        .await
        .expect("connect");
    Rig { _server: server, _dirs: dirs, root, handle }
}

/// A Mac whose hostd predates `bundle`.
async fn serve_old_host(signaling: SignalingClient, uploads: PathBuf) {
    use cmux_mobile_link::dial::{self, DialOptions, SessionEvents};
    std::fs::create_dir_all(&uploads).unwrap();
    while let Some(session) = signaling.next_session().await {
        let first = session.first;
        if cmux_mobile_link::TransportKind::for_first_signal(&first.payload).is_none() {
            continue;
        }
        let events = SessionEvents {
            session: session.events,
            backend: signaling.events(),
            session_id: first.session_id.clone(),
        };
        let options = DialOptions { include_loopback: true, ..DialOptions::default() };
        let connected =
            dial::answer(&signaling, first, events, &options, cmux_mobile_link::LinkConfig::default())
                .await
                .unwrap();
        let uploads = uploads.clone();
        tokio::spawn(async move {
            let _keep = &connected;
            while let Some(incoming) = connected.link.accept().await {
                let uploads = uploads.clone();
                tokio::spawn(async move {
                    let (sender, mut receiver) = incoming.channel.split();
                    if incoming.service != "upload" {
                        sender.close("unknown_service", &format!("no service {}", incoming.service)).await;
                        return;
                    }
                    let size: u64 = incoming.args["size"].as_str().unwrap().parse().unwrap();
                    let mut bytes = Vec::new();
                    while (bytes.len() as u64) < size {
                        match receiver.recv().await {
                            Some(cmux_mobile_link::ChannelEvent::Data(data)) => {
                                bytes.extend_from_slice(&data);
                            }
                            _ => return,
                        }
                    }
                    let path = uploads.join(incoming.args["name"].as_str().unwrap());
                    std::fs::write(&path, &bytes).unwrap();
                    let reply = serde_json::json!({"path": path, "size": size}).to_string();
                    sender.send(reply.into_bytes().into()).await.unwrap();
                    sender.close("eof", "").await;
                });
            }
        });
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_phone_falls_back_to_upload_on_an_old_mac() {
    let rig = rig_with(true).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("old.png");
    std::fs::write(&source, photo(500_000, 5)).unwrap();
    let store = phone.path().join("bundles/mac").to_str().unwrap().to_owned();
    for _ in 0..2 {
        let sent = rig
            .handle
            .upload_file_bundle(
                source.to_str().unwrap().into(),
                "old.png".into(),
                String::new(),
                store.clone(),
            )
            .await
            .unwrap();
        assert!(!sent.bundle, "{sent:?}");
        assert_eq!(sent.sent_bytes, 500_000);
        assert_eq!(sha(Path::new(&sent.path)), sha(&source));
    }
}

/// `len` bytes that do not compress (a photo).
fn photo(len: usize, seed: u64) -> Vec<u8> {
    let mut s = seed | 1;
    (0..len)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s as u8
        })
        .collect()
}

fn sha(path: &Path) -> String {
    format!("{:x}", Sha256::digest(std::fs::read(path).unwrap()))
}

const SIZE: usize = 3 << 20;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_resent_attachment_moves_under_4_kb_and_lands_identical() {
    let rig = rig().await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("shot.png");
    std::fs::write(&source, photo(SIZE, 7)).unwrap();
    let store = phone.path().join("bundles/mac");
    let (src, st, cwd) = (
        source.to_str().unwrap().to_owned(),
        store.to_str().unwrap().to_owned(),
        rig.root.to_str().unwrap().to_owned(),
    );

    let started = Instant::now();
    let first =
        rig.handle.upload_file_bundle(src.clone(), "shot.png".into(), cwd.clone(), st.clone()).await.unwrap();
    let first_ms = started.elapsed().as_millis();
    assert!(first.bundle, "{first:?}");
    assert!(first.sent_bytes >= SIZE as u64, "the first send carries the file: {first:?}");
    assert_eq!(sha(Path::new(&first.path)), sha(&source));

    let started = Instant::now();
    let again =
        rig.handle.upload_file_bundle(src.clone(), "shot.png".into(), cwd.clone(), st.clone()).await.unwrap();
    let again_ms = started.elapsed().as_millis();
    assert!(again.bundle);
    assert!(again.sent_bytes < 4096, "a re-sent attachment sent {} bytes", again.sent_bytes);
    assert_ne!(again.path, first.path, "published beside the first, nothing overwritten");
    assert!(again.path.ends_with("shot 2.png"), "{again:?}");
    assert_eq!(sha(Path::new(&again.path)), sha(&source));

    // The old way, the same file: the whole file crosses.
    let started = Instant::now();
    let plain = upload_plain(&rig, &source, "shot.png").await;
    let plain_ms = started.elapsed().as_millis();
    println!(
        "scoreboard: re-sent attachment ({SIZE} B, loopback): upload {plain} B {plain_ms} ms; bundle first {} B {first_ms} ms, resend {} B {again_ms} ms",
        first.sent_bytes, again.sent_bytes
    );
}

/// What an old phone does (`LinkUpload`): `upload` args, the bytes, the reply. Returns bytes sent.
async fn upload_plain(rig: &Rig, source: &Path, name: &str) -> u64 {
    let bytes = std::fs::read(source).unwrap();
    let args =
        serde_json::json!({"name": name, "size": bytes.len().to_string(), "cwd": rig.root.to_str().unwrap()});
    let channel = rig.handle.open_channel("upload".into(), args.to_string()).await.unwrap();
    for chunk in bytes.chunks(192 << 10) {
        channel.send(chunk.to_vec()).await.unwrap();
    }
    let mut reply = Vec::new();
    let code = loop {
        match channel.recv().await {
            ChannelMessage::Data { bytes } => reply.extend(bytes),
            ChannelMessage::Closed { code, .. } => break code,
        }
    };
    assert_eq!(code, "eof", "{}", String::from_utf8_lossy(&reply));
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    assert_eq!(sha(Path::new(reply["path"].as_str().unwrap())), sha(source));
    bytes.len() as u64
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_old_phones_upload_still_works_on_the_new_mac() {
    let rig = rig().await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("notes.txt");
    std::fs::write(&source, photo(300_000, 3)).unwrap();
    assert_eq!(upload_plain(&rig, &source, "notes.txt").await, 300_000);
    // And the new Mac lists the capability the phone keys on.
    let channel = rig.handle.open_channel("version".into(), String::new()).await.unwrap();
    let ChannelMessage::Data { bytes } = channel.recv().await else { panic!("no version") };
    let version: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert!(version["capabilities"].as_array().unwrap().iter().any(|c| c == "bundle-v1"), "{version}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn opening_a_file_the_phone_holds_moves_under_4_kb() {
    let rig = rig().await;
    let phone = tempfile::tempdir().unwrap();
    let store = phone.path().join("bundles/mac").to_str().unwrap().to_owned();
    // The phone sent this file (an attachment), so it holds its chunks.
    let source = phone.path().join("clip.mov");
    std::fs::write(&source, photo(SIZE, 11)).unwrap();
    let sent = rig
        .handle
        .upload_file_bundle(
            source.to_str().unwrap().into(),
            "clip.mov".into(),
            rig.root.to_str().unwrap().into(),
            store.clone(),
        )
        .await
        .unwrap();

    let started = Instant::now();
    let dest = phone.path().join("opened/clip.mov");
    let opened = rig
        .handle
        .open_file_bundle(sent.path.clone(), dest.to_str().unwrap().into(), store.clone())
        .await
        .unwrap();
    let open_ms = started.elapsed().as_millis();
    assert!(opened.bundle);
    assert_eq!(sha(&dest), sha(&source));
    let moved = opened.sent_bytes + opened.received_bytes;
    // The manifest of a 3 MiB file is ~1.7 KB (48 chunks of 36 bytes); the key and framing the rest.
    assert!(moved < 4096, "an attachment open moved {moved} bytes: {opened:?}");

    // A file the phone never saw: everything crosses, then a second open moves under 4 KB.
    let other = rig.root.join("report.bin");
    std::fs::write(&other, photo(SIZE, 12)).unwrap();
    let cold_started = Instant::now();
    let cold_dest = phone.path().join("opened/report.bin");
    let cold = rig
        .handle
        .open_file_bundle(other.to_str().unwrap().into(), cold_dest.to_str().unwrap().into(), store.clone())
        .await
        .unwrap();
    let cold_ms = cold_started.elapsed().as_millis();
    assert!(cold.received_bytes >= SIZE as u64);
    assert_eq!(sha(&cold_dest), sha(&other));

    // The old `file`, the same file.
    let plain_started = Instant::now();
    let channel = rig
        .handle
        .open_channel("file".into(), serde_json::json!({"path": sent.path}).to_string())
        .await
        .unwrap();
    let mut plain = 0u64;
    loop {
        match channel.recv().await {
            ChannelMessage::Data { bytes } => plain += bytes.len() as u64,
            ChannelMessage::Closed { code, .. } => {
                assert_eq!(code, "eof");
                break;
            }
        }
    }
    let plain_ms = plain_started.elapsed().as_millis();
    println!(
        "scoreboard: attachment open ({SIZE} B, loopback): file {plain} B {plain_ms} ms; bundle held {moved} B {open_ms} ms, cold {} B {cold_ms} ms",
        cold.received_bytes + cold.sent_bytes
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_get_outside_the_shared_roots_is_refused() {
    let rig = rig().await;
    let phone = tempfile::tempdir().unwrap();
    let err = rig
        .handle
        .open_file_bundle(
            "/etc/hosts".into(),
            phone.path().join("x").to_str().unwrap().into(),
            phone.path().join("s").to_str().unwrap().into(),
        )
        .await
        .unwrap_err();
    assert!(err.to_string().contains("forbidden"), "{err}");
}

/// Reads the bundle channel's next length-prefixed message off raw `recv`s.
async fn read_msg(
    channel: &cmux_mobile_link_ffi::ChannelHandle,
    buf: &mut Vec<u8>,
) -> Result<Vec<u8>, String> {
    loop {
        if buf.len() >= 4 {
            let len = u32::from_be_bytes(buf[..4].try_into().unwrap()) as usize;
            if buf.len() >= 4 + len {
                let msg = buf[4..4 + len].to_vec();
                buf.drain(..4 + len);
                return Ok(msg);
            }
        }
        match channel.recv().await {
            ChannelMessage::Data { bytes } => buf.extend(bytes),
            ChannelMessage::Closed { code, .. } => return Err(code),
        }
    }
}

/// Drains the channel to its close code.
async fn close_code(channel: &cmux_mobile_link_ffi::ChannelHandle) -> String {
    loop {
        if let ChannelMessage::Closed { code, .. } = channel.recv().await {
            return code;
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_forged_or_oversized_message_is_refused() {
    let rig = rig().await;
    let cwd = rig.root.to_str().unwrap();
    let put = |name: &str| serde_json::json!({"op": "put", "name": name, "size": 5, "cwd": cwd}).to_string();

    // An offer under another pair's key, twice (the one retry for a stale key is spent): refused.
    let channel = rig.handle.open_channel("bundle".into(), put("forged.txt")).await.unwrap();
    let mut buf = Vec::new();
    let key = read_msg(&channel, &mut buf).await.unwrap();
    assert!(bundle_link::parse_key_message(&key).is_some());
    let other = bundle_link::cmux_bundle::PairKey::derive(&[9; 32]);
    let mut store = bundle_link::cmux_bundle::store::MemStore::default();
    let forged = bundle_link::cmux_bundle::sync::Sender::new(
        &other,
        bundle_link::cmux_bundle::Kind::Attachment,
        b"hello",
        &mut store,
    )
    .unwrap();
    channel.send(bundle_link::frame(&forged.offer()).to_vec()).await.unwrap();
    channel.send(bundle_link::frame(&forged.offer()).to_vec()).await.unwrap();
    let reply = read_msg(&channel, &mut buf).await.unwrap();
    assert!(String::from_utf8_lossy(&reply).contains("bad_request"), "{}", String::from_utf8_lossy(&reply));
    assert_eq!(close_code(&channel).await, "bad_request");

    // A length prefix past the limit: refused before it is read.
    let channel = rig.handle.open_channel("bundle".into(), put("huge.txt")).await.unwrap();
    let mut buf = Vec::new();
    read_msg(&channel, &mut buf).await.unwrap();
    channel.send(((bundle_link::MAX_MESSAGE + 1) as u32).to_be_bytes().to_vec()).await.unwrap();
    assert_eq!(close_code(&channel).await, "bad_request");

    // The right key, but chunks the offer does not name: refused, nothing published.
    let channel = rig.handle.open_channel("bundle".into(), put("swapped.txt")).await.unwrap();
    let mut buf = Vec::new();
    let secret = bundle_link::parse_key_message(&read_msg(&channel, &mut buf).await.unwrap()).unwrap();
    let key = bundle_link::cmux_bundle::PairKey::derive(&secret);
    let mut store = bundle_link::cmux_bundle::store::MemStore::default();
    let honest = bundle_link::cmux_bundle::sync::Sender::new(
        &key,
        bundle_link::cmux_bundle::Kind::Attachment,
        b"hello",
        &mut store,
    )
    .unwrap();
    let swap = bundle_link::cmux_bundle::sync::Sender::new(
        &key,
        bundle_link::cmux_bundle::Kind::Attachment,
        b"HELLO",
        &mut store,
    )
    .unwrap();
    channel.send(bundle_link::frame(&honest.offer()).to_vec()).await.unwrap();
    read_msg(&channel, &mut buf).await.unwrap(); // the want
    // The other bundle's chunk, under this bundle's root and the honest chunk's id: refused.
    let mut forged = vec![1u8, 3];
    forged.extend_from_slice(honest.root());
    let swapped = swap.manifest().chunks[0].id;
    let sealed = store.get_sealed(&swapped);
    bundle_link::cmux_bundle::sync::encode_records(
        [(&honest.manifest().chunks[0].id, sealed.as_slice())],
        &mut forged,
    );
    channel.send(bundle_link::frame(&forged).to_vec()).await.unwrap();
    assert_eq!(close_code(&channel).await, "bad_request");
    let attachments = rig.root.join(".cmux/attachments");
    let published: Vec<_> = walk(&attachments).into_iter().filter(|p| !p.ends_with(".part")).collect();
    assert!(published.is_empty(), "nothing published: {published:?}");
}

trait SealedGet {
    fn get_sealed(&self, id: &[u8; 32]) -> Vec<u8>;
}

impl SealedGet for bundle_link::cmux_bundle::store::MemStore {
    fn get_sealed(&self, id: &[u8; 32]) -> Vec<u8> {
        use bundle_link::cmux_bundle::store::Store;
        self.get(id).unwrap().unwrap()
    }
}

fn walk(dir: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else { return out };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            out.extend(walk(&path));
        } else {
            out.push(path.to_string_lossy().into_owned());
        }
    }
    out
}
