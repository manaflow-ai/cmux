//! `AttachmentUploads` over the Mac's `bundle` service (PROTOCOL.md "bundle"), with Leo's hung send
//! in mind ("it just blocked me endlessly on a send... i also couldnt cancel out of the send"):
//! (a) a re-sent file crosses a small fraction of its bytes and lands whole;
//! (b) a Mac that goes silent before answering a re-send is retried within the engine's bounds, and
//!     the re-send still finishes over `bundle` once it answers;
//! (c) cancel while the Mac is silent mid-bundle returns at once and wakes the waiter;
//! (d) a Mac from before `bundle` still gets the file over `upload`, and the link remembers it.
//!
//! The real hostd runs as a child of this test binary so the test can freeze it (SIGSTOP): the
//! WireGuard link stays up but nothing answers.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link_ffi::{
    AttachmentUploads, CmuxMobileError, ConnectRequest, LinkHandle, Timings, Transport, UploadObserver,
    UploadProgress, UploadSpec, UploadStage, connect_inner,
};
use sha2::{Digest, Sha256};

const READY: &str = "BUNDLE_MAC_READY";
const MIB: u64 = 1 << 20;

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_default()
}

fn services(root: &Path) -> ServiceConfig {
    ServiceConfig {
        tui_socket_dir: root.parent().unwrap().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![root.to_path_buf()],
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        browser: Default::default(),
        surface: Default::default(),
        chief_socket: None,
        agent_tab_host: None,
        uploads_dir: root.parent().unwrap().join("uploads"),
        pairing: None,
    }
}

/// The Mac half: a real hostd until its stdin closes. Started by [`mac_child`].
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "child of the tests below"]
async fn bundle_mac_host_child() {
    if env("BUNDLE_MAC_ROLE") != "host" {
        return;
    }
    let root = PathBuf::from(env("BUNDLE_MAC_ROOT"));
    let mac =
        SignalingClient::connect(&env("BUNDLE_MAC_SIGNALING"), "user:alice", "team", &env("BUNDLE_MAC_ID"))
            .await
            .unwrap();
    tokio::spawn(serve_signaling(
        mac,
        AnswerContext {
            owner_user_id: "alice".into(),
            services: Arc::new(services(&root)),
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

/// A hostd child, the phone's link to it, and the phone's folders.
struct Rig {
    _server: FakeSignaling,
    _dirs: tempfile::TempDir,
    phone: tempfile::TempDir,
    root: PathBuf,
    mac_id: String,
    link: Arc<LinkHandle>,
    child: Child,
}

impl Rig {
    fn store(&self) -> String {
        self.phone.path().join("Caches/bundles").to_str().unwrap().into()
    }

    fn spec(&self, name: &str) -> UploadSpec {
        UploadSpec {
            upload_id: None,
            mac_id: self.mac_id.clone(),
            name: name.into(),
            cwd: Some(self.root.to_str().unwrap().into()),
        }
    }
}

async fn connect(base_url: &str, mac_id: &str) -> Arc<LinkHandle> {
    connect_inner(
        ConnectRequest {
            base_url: base_url.into(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: uuid::Uuid::new_v4().to_string(),
            mac_device_id: mac_id.into(),
            transport: Transport::WireGuard,
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
    .expect("connect")
}

async fn mac_child() -> Rig {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let dirs = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dirs.path()).unwrap().join("work");
    std::fs::create_dir_all(&root).unwrap();
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--ignored", "--exact", "bundle_mac_host_child", "--nocapture", "--test-threads=1"])
        .env("BUNDLE_MAC_ROLE", "host")
        .env("BUNDLE_MAC_SIGNALING", &server.base_url)
        .env("BUNDLE_MAC_ID", &mac_id)
        .env("BUNDLE_MAC_ROOT", &root)
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
    let link = connect(&server.base_url, &mac_id).await;
    Rig { _server: server, _dirs: dirs, phone: tempfile::tempdir().unwrap(), root, mac_id, link, child }
}

/// Bytes that do not repeat (xorshift), so chunking finds nothing to dedupe within the file.
fn noise_file(path: &Path, size: u64, seed: u64) {
    let mut s = seed | 1;
    let bytes: Vec<u8> = (0..size)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s as u8
        })
        .collect();
    std::fs::write(path, bytes).unwrap();
}

fn sha256(path: &Path) -> String {
    format!("{:x}", Sha256::digest(std::fs::read(path).unwrap()))
}

#[derive(Default)]
struct Recorder {
    events: Mutex<Vec<UploadProgress>>,
}

impl UploadObserver for Recorder {
    fn on_progress(&self, progress: UploadProgress) {
        self.events.lock().unwrap().push(progress);
    }
}

fn fast() -> Timings {
    Timings {
        open: Duration::from_secs(2),
        have: Duration::from_secs(2),
        ack_stall: Duration::from_secs(2),
        final_answer: Duration::from_secs(3),
        backoff_start: Duration::from_millis(50),
        backoff_max: Duration::from_millis(500),
        give_up: Duration::from_secs(120),
        progress_interval: Duration::from_millis(20),
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

/// Sends `source` through the engine and returns (the Mac's path, the final progress).
async fn send(uploads: &AttachmentUploads, rig: &Rig, source: &Path, name: &str) -> (String, UploadProgress) {
    let id = uploads.start(rig.spec(name), source.to_str().unwrap().into());
    let path = tokio::time::timeout(Duration::from_secs(120), uploads.wait(id.clone()))
        .await
        .expect("finished")
        .expect("uploaded");
    (path, uploads.progress(id).unwrap())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_resent_attachment_crosses_a_fraction_of_its_bytes_and_lands_whole() {
    let rig = mac_child().await;
    let source = rig.phone.path().join("photo.heic");
    let size = 4 * MIB + 321;
    noise_file(&source, size, 42);
    let recorder = Arc::new(Recorder::default());
    let uploads = AttachmentUploads::with_timings(recorder.clone(), Timings::default());
    uploads.set_link(rig.mac_id.clone(), Some(rig.link.clone()));
    uploads.set_bundle_root(Some(rig.store()));

    let started = Instant::now();
    let (first_path, first) = send(&uploads, &rig, &source, "photo.heic").await;
    let first_ms = started.elapsed().as_millis();
    assert_eq!(sha256(Path::new(&first_path)), sha256(&source));
    assert!(first.sent_bytes >= size, "a first send carries the file: {}", first.sent_bytes);

    let started = Instant::now();
    let (second_path, second) = send(&uploads, &rig, &source, "photo.heic").await;
    let second_ms = started.elapsed().as_millis();
    assert_ne!(first_path, second_path, "a second copy, not a replaced file");
    assert_eq!(sha256(Path::new(&second_path)), sha256(&source));
    assert_eq!(second.stage, UploadStage::Done);
    assert_eq!((second.acked_bytes, second.total_bytes), (size, size));
    assert!(
        second.sent_bytes < size / 10,
        "a re-send crossed {} of {size} bytes: it did not go over bundle",
        second.sent_bytes
    );
    let events = recorder.events.lock().unwrap().clone();
    let acked: Vec<u64> = events
        .iter()
        .filter(|p| p.upload_id == second.upload_id && p.stage != UploadStage::Compressing)
        .map(|p| p.acked_bytes)
        .collect();
    assert!(acked.windows(2).all(|w| w[0] <= w[1]), "acked went back: {acked:?}");
    println!(
        "scoreboard: engine bundle 4 MiB first {} B {first_ms} ms, re-send {} B {second_ms} ms",
        first.sent_bytes, second.sent_bytes
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_mac_silent_on_a_resend_is_retried_within_the_bound_and_finishes_over_bundle() {
    let rig = mac_child().await;
    let source = rig.phone.path().join("clip.mov");
    let size = 6 * MIB + 7;
    noise_file(&source, size, 7);
    let timings = fast();
    let uploads = AttachmentUploads::with_timings(Arc::new(Recorder::default()), timings.clone());
    uploads.set_link(rig.mac_id.clone(), Some(rig.link.clone()));
    uploads.set_bundle_root(Some(rig.store()));
    send(&uploads, &rig, &source, "clip.mov").await;

    // The Mac holds every chunk; now it goes silent before the re-send's first answer.
    signal(&rig.child, libc::SIGSTOP);
    let id = uploads.start(rig.spec("clip.mov"), source.to_str().unwrap().into());
    let progress = |uploads: &AttachmentUploads| uploads.progress(id.clone()).unwrap();
    until("the first attempt", Duration::from_secs(5), || progress(&uploads).attempt >= 1).await;
    // Bounded: open (2 s) or the key (2 s) runs out, then a retry after backoff; never an endless wait.
    let bound = timings.open + timings.have + timings.backoff_max + Duration::from_secs(2);
    let noticed = until("a retry while the Mac was silent", bound, || progress(&uploads).attempt >= 2).await;
    eprintln!("retried the silent Mac after {noticed:?} (bound {bound:?})");
    let stage = progress(&uploads).stage;
    assert!(
        !matches!(stage, UploadStage::Failed | UploadStage::Cancelled | UploadStage::Done),
        "a silent Mac is retried, not failed: {stage:?}"
    );
    tokio::time::sleep(Duration::from_secs(1)).await;
    signal(&rig.child, libc::SIGCONT);

    let path = tokio::time::timeout(Duration::from_secs(60), uploads.wait(id.clone()))
        .await
        .expect("finished after the Mac answered again")
        .expect("uploaded");
    assert_eq!(sha256(Path::new(&path)), sha256(&source));
    let last = progress(&uploads);
    assert!(
        last.sent_bytes < size / 10,
        "the retried re-send crossed {} of {size} bytes: it left bundle",
        last.sent_bytes
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancel_while_the_mac_is_silent_mid_bundle_returns_at_once() {
    let rig = mac_child().await;
    let source = rig.phone.path().join("video.mov");
    let size = 24 * MIB;
    noise_file(&source, size, 99);
    // The shipped bounds: without cancel the attempt would sit up to 15 s / 30 s per wait.
    let uploads = AttachmentUploads::with_timings(Arc::new(Recorder::default()), Timings::default());
    uploads.set_link(rig.mac_id.clone(), Some(rig.link.clone()));
    uploads.set_bundle_root(Some(rig.store()));
    let id = uploads.start(rig.spec("video.mov"), source.to_str().unwrap().into());
    let progress = |uploads: &AttachmentUploads| uploads.progress(id.clone()).unwrap();
    until("bytes on the wire", Duration::from_secs(30), || progress(&uploads).sent_bytes > 2 * MIB).await;
    signal(&rig.child, libc::SIGSTOP);
    tokio::time::sleep(Duration::from_millis(500)).await;
    let before = progress(&uploads);
    assert_eq!(before.stage, UploadStage::Uploading, "{before:?}");
    assert!(before.sent_bytes < size, "still mid-bundle: {before:?}");

    let started = Instant::now();
    uploads.cancel(id.clone());
    let returned = started.elapsed();
    assert!(returned < Duration::from_millis(100), "cancel took {returned:?}");
    let waited =
        tokio::time::timeout(Duration::from_secs(1), uploads.wait(id.clone())).await.expect("waiter woke");
    assert!(
        matches!(&waited, Err(CmuxMobileError::Refused { code, .. }) if code == "cancelled"),
        "{waited:?}"
    );
    assert_eq!(progress(&uploads).stage, UploadStage::Cancelled);
    signal(&rig.child, libc::SIGCONT);
}

/// A Mac whose hostd predates `bundle`: `unknown_service` for it, `upload` as that hostd served it
/// (one final `{path,size}`, no `have`/acks).
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
                                bytes.extend_from_slice(&data)
                            }
                            _ => return,
                        }
                    }
                    let path = uploads.join(format!(
                        "{}-{}",
                        uuid::Uuid::new_v4(),
                        incoming.args["name"].as_str().unwrap()
                    ));
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
async fn an_older_mac_without_bundle_still_gets_the_file_over_upload() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let dirs = tempfile::tempdir().unwrap();
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    tokio::spawn(serve_old_host(mac, dirs.path().join("old-uploads")));
    let link = connect(&server.base_url, &mac_id).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("old.png");
    let size = 3 * MIB + 5;
    noise_file(&source, size, 5);
    let uploads = AttachmentUploads::with_timings(Arc::new(Recorder::default()), fast());
    uploads.set_link(mac_id.clone(), Some(link));
    uploads.set_bundle_root(Some(phone.path().join("bundles").to_str().unwrap().into()));
    let spec = || UploadSpec { upload_id: None, mac_id: mac_id.clone(), name: "old.png".into(), cwd: None };
    for round in 0..2 {
        let id = uploads.start(spec(), source.to_str().unwrap().into());
        let path = tokio::time::timeout(Duration::from_secs(60), uploads.wait(id.clone()))
            .await
            .expect("finished")
            .expect("uploaded over upload");
        assert_eq!(sha256(Path::new(&path)), sha256(&source));
        let last = uploads.progress(id).unwrap();
        assert_eq!(last.stage, UploadStage::Done);
        assert!(last.sent_bytes >= size, "{last:?}");
        if round == 1 {
            // The link remembered the refusal: no bundle attempt first.
            assert_eq!(last.attempt, 1, "{last:?}");
        }
    }
}
