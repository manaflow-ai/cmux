//! A Mac that goes silent mid-upload with the link still up (Leo's hung video send: "it just
//! blocked me endlessly on a send"). The real hostd runs as a child of this test binary; the test
//! freezes it (SIGSTOP), so the WireGuard link stays up but nothing answers. The engine must
//! notice within its stall bound and retry, then finish from the last acked byte once the Mac
//! answers again (SIGCONT). An upload with no reply bound waits forever and fails this test.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link_ffi::{
    AttachmentUploads, ConnectRequest, Timings, Transport, UploadObserver, UploadProgress, UploadSpec,
    UploadStage, connect_inner,
};

const READY: &str = "SILENT_MAC_READY";
const MIB: u64 = 1 << 20;

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_default()
}

/// The Mac half: a real hostd until its stdin closes. Started by the test below.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "child of a_silent_mac_is_noticed_within_the_stall_bound_and_the_upload_resumes"]
async fn silent_mac_host_child() {
    if env("SILENT_MAC_ROLE") != "host" {
        return;
    }
    let root = PathBuf::from(env("SILENT_MAC_ROOT"));
    let services = ServiceConfig {
        tui_socket_dir: root.parent().unwrap().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![root.clone()],
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        browser: Default::default(),
        surface: Default::default(),
        chief_socket: None,
        agent_tab_host: None,
        uploads_dir: root.parent().unwrap().join("uploads"),
        pairing: None,
        viewport_sync: None,
    };
    let mac =
        SignalingClient::connect(&env("SILENT_MAC_SIGNALING"), "user:alice", "team", &env("SILENT_MAC_ID"))
            .await
            .unwrap();
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
    println!("{READY}");
    let _ = std::io::stdout().flush();
    let _ = tokio::task::spawn_blocking(|| std::io::stdin().read_to_end(&mut Vec::new())).await;
}

struct Quiet;
impl UploadObserver for Quiet {
    fn on_progress(&self, _: UploadProgress) {}
}

/// Kills the child when the test ends, however it ends.
struct Child(std::process::Child);
impl Drop for Child {
    fn drop(&mut self) {
        // SAFETY: plain signals to our own child.
        unsafe { libc::kill(self.0.id() as i32, libc::SIGCONT) };
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn signal(child: &Child, sig: i32) {
    // SAFETY: a plain signal to our own child.
    assert_eq!(unsafe { libc::kill(child.0.id() as i32, sig) }, 0);
}

fn file_of(path: &Path, size: u64) {
    let mut file = std::fs::File::create(path).unwrap();
    let block: Vec<u8> = (0..MIB).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
    let mut left = size;
    while left > 0 {
        let n = left.min(MIB) as usize;
        file.write_all(&block[..n]).unwrap();
        left -= n as u64;
    }
}

async fn until(what: &str, within: Duration, mut ready: impl FnMut() -> bool) -> Duration {
    let start = Instant::now();
    while !ready() {
        assert!(start.elapsed() < within, "no {what} within {within:?}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    start.elapsed()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_silent_mac_is_noticed_within_the_stall_bound_and_the_upload_resumes() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let dirs = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dirs.path()).unwrap().join("work");
    std::fs::create_dir_all(&root).unwrap();
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--ignored", "--exact", "silent_mac_host_child", "--nocapture", "--test-threads=1"])
        .env("SILENT_MAC_ROLE", "host")
        .env("SILENT_MAC_SIGNALING", &server.base_url)
        .env("SILENT_MAC_ID", &mac_id)
        .env("SILENT_MAC_ROOT", &root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("host child");
    let stdout = child.stdout.take().unwrap();
    let child = Child(child);
    let ready = tokio::task::spawn_blocking(move || {
        BufReader::new(stdout).lines().map_while(Result::ok).any(|line| line.contains(READY))
    });
    assert!(tokio::time::timeout(Duration::from_secs(60), ready).await.unwrap().unwrap(), "host child ready");

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

    let timings = Timings::default();
    let ack_stall = timings.ack_stall;
    assert_eq!(ack_stall, Duration::from_secs(30));
    let uploads = AttachmentUploads::with_timings(Arc::new(Quiet), timings);
    uploads.set_link(mac_id.clone(), Some(link));
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("silent.bin");
    let size = 48 * MIB + 11;
    file_of(&source, size);
    let spec = UploadSpec {
        upload_id: None,
        mac_id,
        name: "silent.bin".into(),
        cwd: Some(root.to_str().unwrap().into()),
    };
    let id = uploads.start(spec, source.to_str().unwrap().into());
    let progress = |uploads: &AttachmentUploads| uploads.progress(id.clone()).unwrap();

    until("8 MiB acked", Duration::from_secs(60), || progress(&uploads).acked_bytes > 8 * MIB).await;
    signal(&child, libc::SIGSTOP);
    let frozen = progress(&uploads);
    assert_eq!(frozen.stage, UploadStage::Uploading);
    // Bounded: the engine gives up on the silent attempt and tries again (or waits for the Mac),
    // with the person able to cancel all along; never an endless send.
    let noticed = until("a retry after the Mac went silent", ack_stall + Duration::from_secs(10), || {
        let now = progress(&uploads);
        now.attempt > frozen.attempt || now.stage != UploadStage::Uploading
    })
    .await;
    eprintln!("noticed the silent Mac after {noticed:?} (ack stall bound {ack_stall:?})");
    let stage = progress(&uploads).stage;
    assert!(
        !matches!(stage, UploadStage::Failed | UploadStage::Cancelled | UploadStage::Done),
        "a silent Mac is retried, not failed: {stage:?}"
    );
    signal(&child, libc::SIGCONT);

    let path = tokio::time::timeout(Duration::from_secs(180), uploads.wait(id.clone()))
        .await
        .expect("finished after the Mac answered again")
        .expect("uploaded");
    assert_eq!(std::fs::metadata(&path).unwrap().len(), size);
    let last = progress(&uploads);
    assert!(last.sent_bytes < size + size / 2, "sent {} of {size}: it did not resume", last.sent_bytes);
    drop(child);
}
