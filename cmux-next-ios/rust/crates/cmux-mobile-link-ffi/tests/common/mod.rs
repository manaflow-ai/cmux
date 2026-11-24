//! The rig the upload tests share: a real hostd on a fake backend and the phone's link to it.
#![allow(dead_code)]

use std::sync::Arc;

use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link_ffi::{ChannelHandle, ChannelMessage, ConnectRequest, LinkHandle, Transport, connect_inner};

/// A real hostd on a fake backend and the phone's link to it; what has to stay alive.
pub struct UploadRig {
    pub _server: FakeSignaling,
    pub _dirs: tempfile::TempDir,
    /// A shared root of the Mac: a phone upload with `cwd` = `root` lands in
    /// `<root>/.cmux/attachments/phone-<session>/`.
    pub root: std::path::PathBuf,
    pub handle: Arc<LinkHandle>,
}

pub async fn upload_rig(transport: Transport) -> UploadRig {
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
            session_exposure: None,
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
            ultra: cmux_mobile_link::UltraSetting::Off,
        },
        None,
    )
    .await
    .expect("connect");
    UploadRig { _server: server, _dirs: dirs, root, handle }
}


/// Everything a channel answers until it closes: the data and the close code.
pub async fn read_to_close(channel: &ChannelHandle) -> (Vec<u8>, String) {
    let mut reply = Vec::new();
    loop {
        match channel.recv().await {
            ChannelMessage::Data { bytes } => reply.extend(bytes),
            ChannelMessage::Closed { code, .. } => {
                return (reply, code);
            }
        }
    }
}

/// Opens `service` with `args` and returns its one JSON answer and close code.
pub async fn ask(rig: &UploadRig, service: &str, args: serde_json::Value) -> (serde_json::Value, String) {
    let channel = rig.handle.open_channel(service.into(), args.to_string()).await.expect("open");
    let (reply, code) = read_to_close(&channel).await;
    (serde_json::from_slice(&reply).unwrap_or(serde_json::Value::Null), code)
}

/// Asks `upload-status` until its offset is `want` (the Mac notices a closed channel a moment later).
pub async fn wait_for_offset(rig: &UploadRig, id: &str, want: u64) {
    for _ in 0..100 {
        let (reply, _) = ask(rig, "upload-status", serde_json::json!({"id": id})).await;
        if reply["offset"].as_u64() == Some(want) {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("the Mac never kept {want} bytes for {id}");
}
