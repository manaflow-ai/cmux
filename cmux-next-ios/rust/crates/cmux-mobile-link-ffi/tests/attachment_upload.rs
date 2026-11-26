//! An iPhone attachment past the old 100 MiB cap reaches the Mac whole (Leo:
//! "Attachments take arbitrarily large files of any type; there is no size
//! cap"). The phone side is the exported link the app calls (`connect_inner`,
//! `open_channel`, `ChannelHandle::send`), sending what `LinkUpload` sends: the
//! `upload` args as strings, then the file read from disk 192 KiB at a time.
//! The engine under test is `AttachmentUploads`. The Mac side is cmux-mobile-host's real `upload` service.

use std::io::{Read, Write};
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use std::sync::Arc;

use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link_ffi::{
    AttachmentUploads, CmuxMobileError, ConnectRequest, LinkHandle, Timings, Transport, UploadObserver,
    UploadProgress, UploadSpec, UploadStage, VideoPlan, connect_inner, image_plan, video_plan,
};
use sha2::{Digest, Sha256};

/// A real hostd on a fake backend and the phone's link to it; what has to stay alive.
struct UploadRig {
    _server: FakeSignaling,
    _dirs: tempfile::TempDir,
    /// A shared root of the Mac: a phone upload with `cwd` = `root` lands in
    /// `<root>/.cmux/attachments/phone-<session>/`.
    root: std::path::PathBuf,
    handle: Arc<LinkHandle>,
    mac_id: String,
    phone_id: String,
    base_url: String,
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
    let phone_id = uuid::Uuid::new_v4().to_string();
    let handle = connect(&server.base_url, &mac_id, &phone_id, transport).await;
    UploadRig {
        base_url: server.base_url.clone(),
        _server: server,
        _dirs: dirs,
        root,
        handle,
        mac_id,
        phone_id,
    }
}

async fn connect(base_url: &str, mac_id: &str, phone_id: &str, transport: Transport) -> Arc<LinkHandle> {
    connect_inner(
        ConnectRequest {
            base_url: base_url.into(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: phone_id.into(),
            mac_device_id: mac_id.into(),
            transport,
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
    .expect("connect")
}

const MIB: u64 = 1 << 20;

/// A file of `size` bytes with a position-dependent pattern, so any lost, shifted or repeated
/// chunk changes the hash.
fn patterned_file(path: &Path, size: u64) {
    let mut file = std::fs::File::create(path).unwrap();
    let mut buffer = vec![0_u8; 1 << 16];
    let mut written = 0_u64;
    while written < size {
        let n = (size - written).min(buffer.len() as u64) as usize;
        for (i, b) in buffer[..n].iter_mut().enumerate() {
            let at = written + i as u64;
            *b = (at.wrapping_mul(2_654_435_761) >> 13) as u8;
        }
        file.write_all(&buffer[..n]).unwrap();
        written += n as u64;
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

#[derive(Default)]
struct Recorder {
    events: Mutex<Vec<UploadProgress>>,
}

impl UploadObserver for Recorder {
    fn on_progress(&self, progress: UploadProgress) {
        self.events.lock().unwrap().push(progress);
    }
}

impl Recorder {
    fn stages(&self) -> Vec<UploadStage> {
        let mut stages: Vec<UploadStage> = self.events.lock().unwrap().iter().map(|p| p.stage).collect();
        stages.dedup();
        stages
    }
}

fn spec(rig: &UploadRig, name: &str) -> UploadSpec {
    UploadSpec {
        upload_id: None,
        mac_id: rig.mac_id.clone(),
        name: name.into(),
        cwd: Some(rig.root.to_str().unwrap().into()),
    }
}

fn spec_for_mac(rig: &UploadRig, mac_id: String, name: &str) -> UploadSpec {
    UploadSpec { upload_id: None, mac_id, name: name.into(), cwd: Some(rig.root.to_str().unwrap().into()) }
}

fn engine(timings: Timings) -> (Arc<AttachmentUploads>, Arc<Recorder>) {
    let recorder = Arc::new(Recorder::default());
    (AttachmentUploads::with_timings(recorder.clone(), timings), recorder)
}

async fn until(what: &str, mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while !ready() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_20_mb_file_uploads_whole_with_monotone_progress() {
    let rig = upload_rig(Transport::WireGuard).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("clip.bin");
    let size = 20 * MIB + 12_345;
    patterned_file(&source, size);
    let (uploads, recorder) = engine(Timings::default());
    uploads.set_link(rig.mac_id.clone(), Some(rig.handle.clone()));
    let id = uploads.start(spec(&rig, "clip.bin"), source.to_str().unwrap().into());
    let path = uploads.wait(id.clone()).await.expect("uploaded");
    let stored = Path::new(&path);
    assert!(stored.starts_with(rig.root.join(".cmux/attachments")), "{stored:?}");
    assert_eq!(sha256(stored), sha256(&source));
    let last = uploads.progress(id).unwrap();
    assert_eq!(last.stage, UploadStage::Done);
    assert_eq!(last.mac_path.as_deref(), Some(path.as_str()));
    assert_eq!((last.acked_bytes, last.total_bytes), (size, size));
    let events = recorder.events.lock().unwrap().clone();
    let acked: Vec<u64> =
        events.iter().filter(|p| p.stage != UploadStage::Compressing).map(|p| p.acked_bytes).collect();
    assert!(acked.windows(2).all(|w| w[0] <= w[1]), "acked went back: {acked:?}");
    let sent: Vec<u64> = events.iter().map(|p| p.sent_bytes).collect();
    assert!(sent.windows(2).all(|w| w[0] <= w[1]), "sent went back: {sent:?}");
    let stages = recorder.stages();
    assert_eq!(stages.last(), Some(&UploadStage::Done), "{stages:?}");
    assert!(stages.contains(&UploadStage::Uploading), "{stages:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancel_mid_upload_returns_at_once_and_wakes_the_waiter() {
    let rig = upload_rig(Transport::WireGuard).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("big.bin");
    patterned_file(&source, 200 * MIB);
    let (uploads, _recorder) = engine(Timings::default());
    uploads.set_link(rig.mac_id.clone(), Some(rig.handle.clone()));
    let id = uploads.start(spec(&rig, "big.bin"), source.to_str().unwrap().into());
    let waiter = tokio::spawn({
        let (uploads, id) = (uploads.clone(), id.clone());
        async move { uploads.wait(id).await }
    });
    until("some bytes to move", || uploads.progress(id.clone()).is_some_and(|p| p.sent_bytes > 2 * MIB))
        .await;
    let started = Instant::now();
    uploads.cancel(id.clone());
    assert!(started.elapsed() < Duration::from_millis(50), "cancel took {:?}", started.elapsed());
    let answer =
        tokio::time::timeout(Duration::from_secs(2), waiter).await.expect("the waiter woke").unwrap();
    match answer {
        Err(cmux_mobile_link_ffi::CmuxMobileError::Refused { code, .. }) => assert_eq!(code, "cancelled"),
        other => panic!("expected cancelled, got {other:?}"),
    }
    let progress = uploads.progress(id.clone()).unwrap();
    assert_eq!(progress.stage, UploadStage::Cancelled);
    assert!(progress.sent_bytes < 200 * MIB);
    // No later event revives it.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(uploads.progress(id).unwrap().stage, UploadStage::Cancelled);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_replaced_link_resumes_the_upload() {
    let rig = upload_rig(Transport::WireGuard).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("resume.bin");
    let size = 100 * MIB + 777;
    patterned_file(&source, size);
    let timings = Timings { backoff_start: Duration::from_millis(50), ..Timings::default() };
    let (uploads, _recorder) = engine(timings);
    // A stable Mac key sharing the prefix still has a reconnect owner.
    let upload_mac_id = "link-stable".to_owned();
    uploads.set_link(upload_mac_id.clone(), Some(rig.handle.clone()));
    let id = uploads
        .start(spec_for_mac(&rig, upload_mac_id.clone(), "resume.bin"), source.to_str().unwrap().into());
    until("60% of the file", || uploads.progress(id.clone()).is_some_and(|p| p.acked_bytes > 60 * MIB)).await;
    uploads.set_link(upload_mac_id.clone(), None);
    // A redial changes the link session, not the authenticated phone owning the staged bytes.
    let second = connect(&rig.base_url, &rig.mac_id, &rig.phone_id, Transport::WireGuard).await;
    uploads.set_link(upload_mac_id, Some(second));
    let path = uploads.wait(id.clone()).await.expect("uploaded");
    assert_eq!(sha256(Path::new(&path)), sha256(&source));
    let last = uploads.progress(id).unwrap();
    assert!(last.attempt > 1, "attempts: {}", last.attempt);
    // Needs hostd's resumable `upload_id` protocol (cmux-mobile-host services.rs): without it
    // the second attempt restarts at byte 0 and this fails.
    assert!(last.sent_bytes * 2 < size * 3, "sent {} of {size}: it did not resume", last.sent_bytes);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_one_shot_link_disappearance_fails_promptly() {
    let rig = upload_rig(Transport::WireGuard).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("one-shot.bin");
    patterned_file(&source, MIB);
    let one_shot_mac = format!("link-{}", uuid::Uuid::new_v4());
    let timings = Timings { backoff_start: Duration::from_millis(10), ..Timings::default() };
    let (uploads, _recorder) = engine(timings);
    uploads.set_link(one_shot_mac.clone(), Some(rig.handle.clone()));
    let id = uploads
        .start(spec_for_mac(&rig, one_shot_mac.clone(), "one-shot.bin"), source.to_str().unwrap().into());
    uploads.set_link(one_shot_mac, None);

    let result = tokio::time::timeout(Duration::from_secs(2), uploads.wait(id.clone()))
        .await
        .expect("one-shot link failure is bounded")
        .expect_err("one-shot upload must fail when its link disappears");
    assert!(
        matches!(result, CmuxMobileError::Refused { ref code, .. } if code == "link_unavailable"),
        "{result:?}"
    );
    let progress = uploads.progress(id).unwrap();
    assert_eq!(progress.stage, UploadStage::Failed);
    assert_eq!(progress.error_code.as_deref(), Some("link_unavailable"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_no_link_it_waits_for_the_mac_then_finishes() {
    let rig = upload_rig(Transport::WireGuard).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("late.bin");
    let size = 3 * MIB + 5;
    patterned_file(&source, size);
    let (uploads, recorder) = engine(Timings::default());
    let id = uploads.reserve(spec(&rig, "late.bin"));
    assert_eq!(uploads.progress(id.clone()).unwrap().stage, UploadStage::Compressing);
    uploads.compress_progress(id.clone(), 0.5);
    assert_eq!(uploads.progress(id.clone()).unwrap().acked_bytes, 500);
    uploads.file_ready(id.clone(), source.to_str().unwrap().into());
    until("waiting for the Mac", || {
        uploads.progress(id.clone()).unwrap().stage == UploadStage::WaitingForMac
    })
    .await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(uploads.progress(id.clone()).unwrap().stage, UploadStage::WaitingForMac);
    uploads.set_link(rig.mac_id.clone(), Some(rig.handle.clone()));
    let path = uploads.wait(id.clone()).await.expect("uploaded");
    assert_eq!(sha256(Path::new(&path)), sha256(&source));
    let stages = recorder.stages();
    assert_eq!(stages.first(), Some(&UploadStage::Compressing));
    assert!(
        stages.contains(&UploadStage::WaitingForMac) && stages.last() == Some(&UploadStage::Done),
        "{stages:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_tab_folder_the_mac_cannot_check_falls_back_to_the_uploads_folder() {
    // The cwd is outside the roots, so hostd asks its daemon, which is not running here:
    // `unavailable`. Retrying the same cwd would never finish; the uploads folder needs no daemon.
    let rig = upload_rig(Transport::WireGuard).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("tab.bin");
    patterned_file(&source, MIB + 3);
    let (uploads, _recorder) = engine(Timings::default());
    uploads.set_link(rig.mac_id.clone(), Some(rig.handle.clone()));
    let mut outside = spec(&rig, "tab.bin");
    outside.cwd = Some(phone.path().to_str().unwrap().into());
    let id = uploads.start(outside, source.to_str().unwrap().into());
    let path = tokio::time::timeout(Duration::from_secs(20), uploads.wait(id))
        .await
        .expect("bounded: it fell back instead of retrying the tab folder")
        .expect("uploaded");
    assert!(!path.starts_with(phone.path().to_str().unwrap()), "{path}");
    assert_eq!(sha256(Path::new(&path)), sha256(&source));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_missing_file_fails_unreadable_and_a_given_id_is_kept() {
    let rig = upload_rig(Transport::WireGuard).await;
    let (uploads, _recorder) = engine(Timings::default());
    let mut given = spec(&rig, "nope.bin");
    given.upload_id = Some("0123abcd-0000-4000-8000-000000000000".into());
    let id = uploads.start(given, "/definitely/not/here".into());
    assert_eq!(id, "0123abcd-0000-4000-8000-000000000000");
    assert!(uploads.wait(id.clone()).await.is_err());
    let progress = uploads.progress(id).unwrap();
    assert_eq!((progress.stage, progress.error_code.as_deref()), (UploadStage::Failed, Some("unreadable")));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_wait_that_starts_after_the_upload_ended_still_gets_its_result() {
    // The result used to be stored with watch `send`, which keeps nothing when no waiter is
    // subscribed yet: a `wait` after a cancel (or a fast failure) then hung forever.
    let rig = upload_rig(Transport::WireGuard).await;
    let (uploads, _recorder) = engine(Timings::default());
    let failed = uploads.start(spec(&rig, "nope.bin"), "/definitely/not/here".into());
    let deadline = Instant::now() + Duration::from_secs(10);
    while !uploads.progress(failed.clone()).unwrap().stage.eq(&UploadStage::Failed) {
        assert!(Instant::now() < deadline, "the missing file never failed");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let late = tokio::time::timeout(Duration::from_secs(1), uploads.wait(failed)).await;
    assert!(matches!(late, Ok(Err(_))), "{late:?}");

    let cancelled = uploads.start(spec(&rig, "nope.bin"), "/definitely/not/here/either".into());
    uploads.cancel(cancelled.clone());
    let late = tokio::time::timeout(Duration::from_secs(1), uploads.wait(cancelled)).await;
    assert!(
        matches!(&late, Ok(Err(CmuxMobileError::Refused { code, .. })) if code == "cancelled" || code == "unreadable"),
        "{late:?}"
    );
}

/// Uploads `source` as a new attachment; its stored path and the payload bytes it sent.
async fn send_once(uploads: &AttachmentUploads, rig: &UploadRig, source: &Path, name: &str) -> (String, u64) {
    let id = uploads.start(spec(rig, name), source.to_str().unwrap().into());
    let path = uploads.wait(id.clone()).await.expect("uploaded");
    let last = uploads.progress(id).unwrap();
    assert_eq!(last.stage, UploadStage::Done);
    assert_eq!(last.acked_bytes, last.total_bytes);
    (path, last.sent_bytes)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_re_upload_of_the_same_file_crosses_no_bytes_and_finishes() {
    let rig = upload_rig(Transport::WireGuard).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("photo.heic");
    let size = 8 * MIB + 321;
    patterned_file(&source, size);
    let (uploads, _recorder) = engine(Timings::default());
    uploads.set_link(rig.mac_id.clone(), Some(rig.handle.clone()));
    let (first_path, first_sent) = send_once(&uploads, &rig, &source, "photo.heic").await;
    assert_eq!(first_sent, size);
    // The same picture picked again (a new attachment, same bytes).
    let started = Instant::now();
    let (again_path, again_sent) = send_once(&uploads, &rig, &source, "photo.heic").await;
    eprintln!(
        "dedup wire payload: first send {first_sent} bytes, re-send {again_sent} bytes ({:?})",
        started.elapsed()
    );
    assert_eq!(again_sent, 0, "the re-send crossed payload bytes");
    assert_eq!(again_path, first_path, "the Mac answers its stored copy");
    assert_eq!(sha256(Path::new(&again_path)), sha256(&source));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_deleted_or_changed_stored_copy_falls_back_to_a_full_upload() {
    let rig = upload_rig(Transport::WireGuard).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("clip.mov");
    let size = 3 * MIB + 77;
    patterned_file(&source, size);
    let (uploads, _recorder) = engine(Timings::default());
    uploads.set_link(rig.mac_id.clone(), Some(rig.handle.clone()));
    let (first, _) = send_once(&uploads, &rig, &source, "clip.mov").await;
    std::fs::remove_file(&first).unwrap();
    let (second, sent) = send_once(&uploads, &rig, &source, "clip.mov").await;
    assert_eq!(sent, size, "a deleted copy is sent again whole");
    assert_eq!(sha256(Path::new(&second)), sha256(&source));
    // Same size, other bytes: the Mac re-hashes and takes the bytes again.
    std::fs::write(&second, vec![0_u8; size as usize]).unwrap();
    let (third, sent) = send_once(&uploads, &rig, &source, "clip.mov").await;
    assert_eq!(sent, size, "a changed copy is sent again whole");
    assert_eq!(sha256(Path::new(&third)), sha256(&source));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_re_encoded_image_lands_under_the_name_the_encoder_gave_it() {
    let rig = upload_rig(Transport::WireGuard).await;
    let phone = tempfile::tempdir().unwrap();
    let source = phone.path().join("IMG_0001.jpg");
    patterned_file(&source, 300_000);
    let (uploads, _recorder) = engine(Timings::default());
    uploads.set_link(rig.mac_id.clone(), Some(rig.handle.clone()));
    let id = uploads.reserve(spec(&rig, "IMG_0001.HEIC"));
    uploads.file_ready_as(id.clone(), source.to_str().unwrap().into(), "IMG_0001.jpg".into());
    let path = uploads.wait(id).await.expect("uploaded");
    assert!(path.ends_with("/IMG_0001.jpg"), "{path}");
    assert_eq!(sha256(Path::new(&path)), sha256(&source));
}

fn plan(width: u32, height: u32, seconds: u64, bytes: u64) -> VideoPlan {
    video_plan(width, height, seconds * 1000, bytes, "hevc".into())
}

#[test]
fn video_plan_sends_small_or_modest_originals_and_reencodes_the_rest() {
    // Small: as is, even at 4K.
    assert!(!plan(3840, 2160, 3, 20 * MIB).reencode);
    // 1080p at 8 Mbit/s for 60 s (60 MB): as is; portrait counts by its long side.
    assert!(!plan(1920, 1080, 60, 60_000_000).reencode);
    assert!(!plan(1080, 1920, 60, 60_000_000).reencode);
    // 1080p at 20 Mbit/s: heavy.
    let heavy = plan(1920, 1080, 60, 150_000_000);
    assert!(
        heavy.reencode && heavy.max_long_side == 1920 && heavy.preset == "AVAssetExportPresetHEVC1920x1080"
    );
    // A minute of 4K.
    let uhd = plan(3840, 2160, 60, 170_000_000);
    assert!(uhd.reencode && !uhd.reason.is_empty());
    // 4K even at a tiny bitrate is bigger than 1080p.
    assert!(plan(3840, 2160, 600, 30 * MIB).reencode);
    // Big file of unknown length: re-encode.
    assert!(video_plan(1280, 720, 0, 100 * MIB, "h264".into()).reencode);
    // The 25 MiB edge.
    assert!(!plan(3840, 2160, 10, 25 * MIB).reencode);
    assert!(plan(3840, 2160, 10, 25 * MIB + 1).reencode);
}

#[test]
fn image_plan_sends_small_originals_and_downscales_the_rest_to_a_2048px_jpeg() {
    let jpeg = |w, h, bytes| image_plan(w, h, bytes, "jpeg".into());
    // At both edges: as is.
    let edge = jpeg(1290, 2048, 2 * MIB);
    assert_eq!((edge.reencode, edge.max_long_side), (false, 2048));
    // An iPhone screenshot (1179 x 2556) is longer than 2048: downscaled.
    assert!(jpeg(1179, 2556, 600_000).reencode);
    assert!(!jpeg(1920, 1080, 900_000).reencode);
    let small = jpeg(800, 600, 200_000);
    assert_eq!((small.reencode, small.max_long_side, small.quality), (false, 800, 1.0));
    // The 2 MiB edge at a small size: re-encoded at its own size, never upscaled.
    let heavy = jpeg(2000, 1500, 2 * MIB + 1);
    assert_eq!((heavy.reencode, heavy.max_long_side, heavy.quality), (true, 2000, 0.85));
    // A 12 MP HEIC photo (4032 x 3024, about 2.5 MB): a 2048px JPEG, portrait too.
    let photo = image_plan(4032, 3024, 2_500_000, "heic".into());
    assert_eq!((photo.reencode, photo.max_long_side, photo.quality), (true, 2048, 0.85));
    assert!(photo.reason.contains("heic"), "{}", photo.reason);
    assert_eq!(image_plan(3024, 4032, 1_000_000, "heic".into()).max_long_side, 2048);
    // The long-side edge.
    assert!(!jpeg(2048, 10, 1).reencode);
    assert!(jpeg(2049, 10, 1).reencode);
    // Unknown size and big: the 2048px cap.
    let unknown = jpeg(0, 0, 10 * MIB);
    assert_eq!((unknown.reencode, unknown.max_long_side), (true, 2048));
}
