//! A Mac from before whole-file dedup ignores the `sha256` the phone now sends: every upload,
//! a re-send of the same file too, crosses whole and finishes. Its own test binary, because it
//! turns hostd's dedup off for the process (`UPLOAD_DEDUP`), as an older hostd is.

use std::io::Write;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_host::services::UPLOAD_DEDUP;
use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link_ffi::{
    AttachmentUploads, ConnectRequest, Timings, Transport, UploadObserver, UploadProgress, UploadSpec,
    UploadStage, connect_inner,
};
use sha2::{Digest, Sha256};

struct Quiet;
impl UploadObserver for Quiet {
    fn on_progress(&self, _: UploadProgress) {}
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_mac_ignoring_sha256_still_gets_every_upload_whole() {
    UPLOAD_DEDUP.store(false, Ordering::Relaxed);
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
    let link = connect_inner(
        ConnectRequest {
            base_url: server.base_url.clone(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: uuid::Uuid::new_v4().to_string(),
            mac_device_id: mac_id.clone(),
            transport: Transport::WireGuard,
            include_loopback: true,
            relay_only: false,
            block_udp: false,
            video_lane: false,
            webrtc_media: false,
            ultra: cmux_mobile_link::UltraSetting::Off,
            proxy_only: false,
            drop_wireguard: false,
            force_relay: false,
        },
        None,
    )
    .await
    .expect("connect");

    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("same.bin");
    let content: Vec<u8> =
        (0..(2 << 20) + 5).map(|i: u32| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
    std::fs::File::create(&source).unwrap().write_all(&content).unwrap();
    let uploads = AttachmentUploads::with_timings(Arc::new(Quiet), Timings::default());
    uploads.set_link(mac_id.clone(), Some(link));
    let mut paths = Vec::new();
    for _ in 0..2 {
        let spec = UploadSpec {
            upload_id: None,
            mac_id: mac_id.clone(),
            name: "same.bin".into(),
            cwd: Some(root.to_str().unwrap().into()),
        };
        let id = uploads.start(spec, source.to_str().unwrap().into());
        let path = uploads.wait(id.clone()).await.expect("uploaded");
        let last = uploads.progress(id).unwrap();
        assert_eq!(last.stage, UploadStage::Done);
        assert_eq!(last.sent_bytes, content.len() as u64, "an older Mac takes every byte");
        assert_eq!(Sha256::digest(std::fs::read(Path::new(&path)).unwrap()), Sha256::digest(&content));
        paths.push(path);
    }
    assert_ne!(paths[0], paths[1], "an older Mac stores each upload anew");
}
