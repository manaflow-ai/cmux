//! An iPhone attachment past the old 100 MiB cap reaches the Mac whole (Leo:
//! "Attachments take arbitrarily large files of any type; there is no size
//! cap"). The phone side is the exported link the app calls (`connect_inner`,
//! `open_channel`, `ChannelHandle::send`), sending what `LinkUpload` sends: the
//! `upload` args as strings, then the file read from disk 192 KiB at a time.
//! The Mac side is cmux-mobile-host's real `upload` service.

use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use std::sync::Arc;

use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link_ffi::{ChannelMessage, ConnectRequest, LinkHandle, Transport, connect_inner};
use sha2::{Digest, Sha256};

/// A real hostd on a fake backend and the phone's link to it; what has to stay alive.
struct UploadRig {
    _server: FakeSignaling,
    _dirs: tempfile::TempDir,
    /// A shared root of the Mac: a phone upload with `cwd` = `root` lands in
    /// `<root>/.cmux/attachments/phone-<session>/`.
    root: std::path::PathBuf,
    handle: Arc<LinkHandle>,
}

async fn upload_rig(transport: Transport) -> UploadRig {
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
    };
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    tokio::spawn(serve_signaling(
        mac,
        AnswerContext {
            owner_user_id: "alice".into(),
            services: Arc::new(services),
            ice: IceSource::Fixed(Vec::new()),
            include_loopback: true,
            exclude_cgnat: false,
            mailbox: None,
        },
    ));
    let handle = connect_inner(
        ConnectRequest {
            base_url: server.base_url.clone(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: uuid::Uuid::new_v4().to_string(),
            mac_device_id: mac_id,
            transport,
            include_loopback: true,
            relay_only: false,
            block_udp: false,
            video_lane: false,
            webrtc_media: false,
        },
        None,
    )
    .await
    .expect("connect");
    UploadRig { _server: server, _dirs: dirs, root, handle }
}

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
