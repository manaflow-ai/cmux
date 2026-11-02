//! A streamed browser tab end to end: the exported viewer, a real link over
//! both transports, cmux-mobile-host's `browser` service, and a stand-in host.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_link::SignalingClient;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link_ffi::{BrowserFrame, BrowserObserver, ConnectRequest, Transport, connect_inner};

#[path = "../../cmux-mobile-host/tests/support/fake_rb_host.rs"]
mod fake_rb_host;

#[derive(Default)]
struct Recorder {
    frames: Mutex<Vec<BrowserFrame>>,
    messages: Mutex<Vec<serde_json::Value>>,
    closed: Mutex<Option<String>>,
}

impl BrowserObserver for Recorder {
    fn on_frame(&self, frame: BrowserFrame) {
        self.frames.lock().unwrap().push(frame);
    }
    fn on_message(&self, json: String) {
        self.messages.lock().unwrap().push(serde_json::from_str(&json).unwrap());
    }
    fn on_closed(&self, code: String, _reason: String) {
        *self.closed.lock().unwrap() = Some(code);
    }
}

impl Recorder {
    async fn until(&self, what: &str, check: impl Fn(&Recorder) -> bool) {
        for _ in 0..400 {
            if check(self) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("timed out waiting for {what}; messages {:?}", self.messages.lock().unwrap());
    }

    fn has(&self, t: &str, key: &str, value: &str) -> bool {
        self.messages
            .lock()
            .unwrap()
            .iter()
            .any(|m| m["t"] == t && m[key].as_str().is_some_and(|v| v.contains(value)))
    }
}

/// A link to a hostd with the stand-in browser host; what has to stay alive.
struct Rig {
    _server: FakeSignaling,
    _sockets: tempfile::TempDir,
    handle: Arc<cmux_mobile_link_ffi::LinkHandle>,
}

async fn rig(transport: Transport, video_lane: bool) -> Rig {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let sockets = tempfile::tempdir().unwrap();
    let launches = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let services = ServiceConfig {
        tui_socket_dir: sockets.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: Vec::new(),
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        browser: cmux_mobile_host::browser::BrowserConfig::new(Some(fake_rb_host::launcher(launches)), 2),
        surface: Default::default(),
        chief_socket: None,
        agent_tab_host: None,
        uploads_dir: sockets.path().join("uploads"),
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
            video_lane,
            webrtc_media: false,
        },
        None,
    )
    .await
    .expect("connect");
    Rig { _server: server, _sockets: sockets, handle }
}

async fn stream_over(transport: Transport, video_lane: bool) {
    let rig = rig(transport, video_lane).await;
    let recorder = Arc::new(Recorder::default());
    let stream = rig
        .handle
        .open_browser(r#"{"tab":"s3","url":"https://example.com/"}"#.into(), recorder.clone())
        .await
        .unwrap();
    recorder.until("welcome", |r| r.has("welcome", "encoder", "fake")).await;
    recorder.until("rb.page", |r| r.has("rb.page", "url", "example.com")).await;
    stream
        .send_message(
            serde_json::json!({"t": "rb.open", "tab": "s3", "profile": "default", "viewer": "phone",
                "screen": {"css_width": 402, "css_height": 760, "scale": 2.0, "refresh_hz": 60, "color_space": "srgb"},
                "caps": {"codecs": ["h264"], "tile_codecs": [], "max_fps": 60}})
            .to_string(),
        )
        .unwrap();
    recorder
        .until("rb.screen_applied", |r| {
            r.messages
                .lock()
                .unwrap()
                .iter()
                .any(|m| m["t"] == "rb.screen_applied" && m["pixel_width"] == 804.0)
        })
        .await;
    // Frames arrive whole, the first a keyframe, and get an age once the clock is estimated.
    recorder
        .until("frames with an age", |r| r.frames.lock().unwrap().iter().any(|f| f.age_us.is_some()))
        .await;
    recorder.until("a P-frame", |r| r.frames.lock().unwrap().iter().any(|f| !f.keyframe)).await;
    {
        let frames = recorder.frames.lock().unwrap();
        assert!(frames[0].keyframe);
        // SPS, PPS and the IDR slice of the stand-in host, byte for byte
        // whichever way they came.
        assert_eq!(&frames[0].access_unit[..5], &[0, 0, 0, 1, 0x67]);
        assert_eq!(frames[0].access_unit.len(), 18 + 5 + 4 + 2500);
        let p = frames.iter().find(|f| !f.keyframe).unwrap();
        assert_eq!(p.access_unit.len(), 5 + 4 + 2500, "{:?}", &p.access_unit[..12]);
        let aged = frames.iter().find_map(|f| f.age_us).unwrap();
        assert!((0..2_000_000).contains(&aged), "age {aged}");
    }
    stream.send_message(r#"{"t":"rb.navigate","url":"https://example.org/x"}"#.into()).unwrap();
    recorder.until("navigated", |r| r.has("rb.page", "url", "example.org/x")).await;
    stream
        .send_input(
            r#"{"e":"pointer","surface":0,"kind":"down","x":10.0,"y":20.0,"button":0,"buttons":1,"click_count":1,"modifiers":0,"pointer_type":"touch"}"#
                .into(),
            true,
        )
        .unwrap();
    stream
        .send_input(r#"{"e":"ime_commit","surface":0,"text":"héllo","replacement":null}"#.into(), true)
        .unwrap();
    recorder.until("input reached the page", |r| r.has("rb.tooltip", "text", "pointer")).await;
    recorder.until("text reached the page", |r| r.has("rb.tooltip", "text", "héllo")).await;
    assert!(stream.send_message(r#"{"t":"welcome"}"#.into()).is_err());
    let stats = stream.stats();
    assert!(stats.frames >= 1 && stats.bytes >= 2500 && stats.clock_offset_us.is_some());
    // With the lane offered the video rides it on either transport.
    assert_eq!(stats.video_track, video_lane, "{stats:?}");
    stream.close();
    recorder.until("closed", |r| r.closed.lock().unwrap().is_some()).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn browser_stream_over_webrtc() {
    stream_over(Transport::WebRtc, false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn browser_stream_over_the_webrtc_video_track() {
    stream_over(Transport::WebRtc, true).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn browser_stream_over_rtp_inside_the_wireguard_tunnel() {
    stream_over(Transport::WireGuard, true).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn browser_stream_over_wireguard() {
    stream_over(Transport::WireGuard, false).await;
}

/// WireGuard for the link, a WebRTC media session for the tab's video
/// (verify/hybrid-link.md): the shown tab opens the session, video moves
/// onto its track, falls back into the tunnel when it dies, and comes back
/// when the phone's next session is up. hostd answers the session
/// (`media_session.rs`) exactly as in production.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn browser_video_rides_the_media_session_beside_wireguard() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let sockets = tempfile::tempdir().unwrap();
    let launches = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let services = ServiceConfig {
        tui_socket_dir: sockets.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: Vec::new(),
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        browser: cmux_mobile_host::browser::BrowserConfig::new(Some(fake_rb_host::launcher(launches)), 2),
        surface: Default::default(),
        chief_socket: None,
        agent_tab_host: None,
        uploads_dir: sockets.path().join("uploads"),
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
            transport: Transport::WireGuard,
            include_loopback: true,
            relay_only: false,
            block_udp: false,
            video_lane: true,
            webrtc_media: true,
        },
        None,
    )
    .await
    .expect("connect");
    // Nothing opens before a tab wants video.
    assert_eq!(handle.media_state(), cmux_mobile_link_ffi::MediaState::Off);
    let recorder = Arc::new(Recorder::default());
    let stream = handle
        .open_browser(r#"{"tab":"s3","url":"https://example.com/"}"#.into(), recorder.clone())
        .await
        .unwrap();
    recorder.until("welcome", |r| r.has("welcome", "encoder", "fake")).await;
    stream
        .send_message(
            serde_json::json!({"t": "rb.open", "tab": "s3", "profile": "default", "viewer": "phone",
                "screen": {"css_width": 402, "css_height": 760, "scale": 2.0, "refresh_hz": 60, "color_space": "srgb"},
                "caps": {"codecs": ["h264"], "tile_codecs": [], "max_fps": 60}})
            .to_string(),
        )
        .unwrap();
    let carrier = |want: &'static str| {
        let stream = Arc::clone(&stream);
        move |_: &Recorder| stream.stats().video_carrier == want
    };
    recorder.until("video on the media session", carrier("webrtc-track")).await;
    assert!(
        matches!(handle.media_state(), cmux_mobile_link_ffi::MediaState::Up { .. }),
        "{:?}",
        handle.media_state()
    );
    let before = recorder.frames.lock().unwrap().len();
    // The session dies: video falls back into the tunnel and keeps coming.
    handle.kill_media();
    recorder.until("video back in the tunnel", carrier("wireguard-udp")).await;
    recorder.until("frames after the fallback", |r| r.frames.lock().unwrap().len() > before + 10).await;
    // The next session takes it back.
    for _ in 0..3 {
        if stream.stats().video_carrier == "webrtc-track" {
            break;
        }
        recorder.until("video on the next media session", carrier("webrtc-track")).await;
    }
    assert_eq!(stream.stats().video_carrier, "webrtc-track");
    stream.close();
    recorder.until("closed", |r| r.closed.lock().unwrap().is_some()).await;
}

fn open_message(tab: &str) -> String {
    serde_json::json!({"t": "rb.open", "tab": tab, "profile": "default", "viewer": "phone",
        "screen": {"css_width": 402, "css_height": 760, "scale": 2.0, "refresh_hz": 60, "color_space": "srgb"},
        "caps": {"codecs": ["h264"], "tile_codecs": [], "max_fps": 60}})
    .to_string()
}

/// transport-verify-20261019.md defect 7: the last `browser` channel to
/// open takes the link's one media lane, so after a redial a hidden tab
/// could hold it while the shown one fell back to the channel. The tab the
/// phone shows (`rb.visibility` true) takes the lane back, on every carrier
/// of the lane.
async fn the_shown_tab_takes_the_media_lane_back(
    transport: Transport,
    webrtc_media: bool,
    lane: &'static str,
) {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let sockets = tempfile::tempdir().unwrap();
    let launches = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let services = ServiceConfig {
        tui_socket_dir: sockets.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: Vec::new(),
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        browser: cmux_mobile_host::browser::BrowserConfig::new(Some(fake_rb_host::launcher(launches)), 4),
        surface: Default::default(),
        chief_socket: None,
        agent_tab_host: None,
        uploads_dir: sockets.path().join("uploads"),
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
            video_lane: true,
            webrtc_media,
        },
        None,
    )
    .await
    .expect("connect");
    let shown = Arc::new(Recorder::default());
    let a = handle
        .open_browser(r#"{"tab":"s3","url":"https://example.com/a"}"#.into(), shown.clone())
        .await
        .unwrap();
    shown.until("welcome", |r| r.has("welcome", "encoder", "fake")).await;
    a.send_message(open_message("s3")).unwrap();
    let on = |stream: &Arc<cmux_mobile_link_ffi::BrowserStream>, want: &'static str| {
        let stream = Arc::clone(stream);
        move |_: &Recorder| stream.stats().video_carrier == want
    };
    shown.until("the shown tab on the lane", on(&a, lane)).await;

    // A hidden tab opens after it (as every held tab did after a redial)
    // and takes the lane; the shown tab's video returns to its channel.
    let hidden = Arc::new(Recorder::default());
    let b = handle
        .open_browser(r#"{"tab":"s4","url":"https://example.com/b"}"#.into(), hidden.clone())
        .await
        .unwrap();
    hidden.until("welcome", |r| r.has("welcome", "encoder", "fake")).await;
    b.send_message(open_message("s4")).unwrap();
    b.set_visible(false);
    b.send_message(r#"{"t":"rb.visibility","visible":false}"#.into()).unwrap();
    shown.until("the shown tab on its channel", on(&a, "channel")).await;

    // The phone says which tab is shown: it takes the lane back, starting
    // at a keyframe, and the hidden tab's video goes to its channel.
    a.send_message(r#"{"t":"rb.visibility","visible":true}"#.into()).unwrap();
    shown.until("the shown tab back on the lane", on(&a, lane)).await;
    let before = shown.frames.lock().unwrap().len();
    shown.until("frames on the lane", |r| r.frames.lock().unwrap().len() > before + 10).await;
    assert_eq!(a.stats().video_carrier, lane);
    hidden.until("the hidden tab on its channel", on(&b, "channel")).await;
    a.close();
    b.close();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_shown_tab_takes_the_lane_back_over_wireguard_rtp() {
    the_shown_tab_takes_the_media_lane_back(Transport::WireGuard, false, "wireguard-udp").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_shown_tab_takes_the_lane_back_over_the_media_session() {
    the_shown_tab_takes_the_media_lane_back(Transport::WireGuard, true, "webrtc-track").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_shown_tab_takes_the_lane_back_over_webrtc() {
    the_shown_tab_takes_the_media_lane_back(Transport::WebRtc, false, "webrtc-track").await;
}

/// The real CEF browser host (`CMUX_MOBILE_RB_HOST_EXE`, e.g. a DEV app's
/// `Contents/Helpers/cmux-remote-browser-host.app/Contents/MacOS/...`) over
/// the WebRTC video track, with a page from `CMUX_MOBILE_RB_URL`. Measurement support,
/// not part of the suite: `cargo test -p cmux-mobile-link-ffi --test browser real_host -- --ignored --nocapture`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs a real browser host"]
async fn real_host_over_the_track() {
    let Ok(exe) = std::env::var("CMUX_MOBILE_RB_HOST_EXE") else { return };
    let url = std::env::var("CMUX_MOBILE_RB_URL").unwrap_or_else(|_| "about:blank".into());
    let video_lane = std::env::var("CMUX_MOBILE_RB_CHANNEL").is_err();
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let sockets = tempfile::tempdir().unwrap();
    let services = ServiceConfig {
        tui_socket_dir: sockets.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: Vec::new(),
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        browser: cmux_mobile_host::browser::BrowserConfig::process(
            exe.into(),
            std::env::var("CMUX_MOBILE_RB_CACHE").map_or_else(|_| sockets.path().join("rb"), Into::into),
            2,
        ),
        surface: Default::default(),
        chief_socket: None,
        agent_tab_host: None,
        uploads_dir: sockets.path().join("uploads"),
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
            transport: Transport::WebRtc,
            include_loopback: true,
            relay_only: false,
            block_udp: false,
            video_lane,
            webrtc_media: false,
        },
        None,
    )
    .await
    .expect("connect");
    let recorder = Arc::new(Recorder::default());
    let stream = handle
        .open_browser(serde_json::json!({"tab": "real", "url": url}).to_string(), recorder.clone())
        .await
        .unwrap();
    recorder.until("welcome", |r| r.messages.lock().unwrap().iter().any(|m| m["t"] == "welcome")).await;
    stream
        .send_message(
            serde_json::json!({"t": "rb.open", "tab": "real", "profile": "default", "viewer": "phone",
                "screen": {"css_width": 402, "css_height": 722, "scale": 2.0, "refresh_hz": 60, "color_space": "srgb"},
                "caps": {"codecs": ["h264"], "tile_codecs": [], "max_fps": 60}})
            .to_string(),
        )
        .unwrap();
    for second in 0..8 {
        tokio::time::sleep(Duration::from_secs(1)).await;
        let frames = recorder.frames.lock().unwrap();
        let keyframes = frames.iter().filter(|f| f.keyframe).count();
        let first = frames.first().map(|f| f.access_unit.iter().take(12).copied().collect::<Vec<_>>());
        println!(
            "t={second}s frames={} keyframes={keyframes} stats={:?} first={first:?}",
            frames.len(),
            stream.stats()
        );
    }
    let msgs: Vec<String> = recorder.messages.lock().unwrap().iter().map(|m| m["t"].to_string()).collect();
    println!("messages: {msgs:?}");
    assert!(recorder.frames.lock().unwrap().len() > 30);
    stream.close();
}

#[path = "../../cmux-mobile-host/tests/support/fake_surface_source.rs"]
mod fake_surface_source;

/// A stand-in daemon whose one workspace has phone tab `s12` (a Mac phone tab
/// showing a simulator).
fn phone_tab_daemon(dir: &std::path::Path) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let listener = tokio::net::UnixListener::bind(dir.join("main.sock")).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                    let answer = serde_json::json!({"id": request["id"], "ok": true, "data": {"workspaces": [{"screens": [{"panes": [
                        {"tabs": [{"surface": 12, "kind": "conversation", "conversation": {"page": "phone", "route": "sim:A"}}]}]}]}]}});
                    write.write_all(format!("{answer}\n").as_bytes()).await.unwrap();
                }
            });
        }
    });
}

/// A simulator surface end to end through the exported viewer: the phone
/// opens a Mac phone tab, its frames arrive whole (a keyframe first), and
/// taps, drags, typing, keys and the Home button reach the simulator's source
/// as touches at 0...1 of its screen, text, keys and buttons.
async fn surface_over(transport: Transport, video_lane: bool) {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let sockets = tempfile::tempdir().unwrap();
    phone_tab_daemon(sockets.path());
    let inputs = fake_surface_source::Inputs::default();
    let services = ServiceConfig {
        tui_socket_dir: sockets.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: Vec::new(),
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        browser: cmux_mobile_host::browser::BrowserConfig::default(),
        surface: cmux_mobile_host::surface::SurfaceConfig::new(
            Some(fake_surface_source::launcher(inputs.clone())),
            2,
        ),
        chief_socket: None,
        agent_tab_host: None,
        uploads_dir: sockets.path().join("uploads"),
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
            video_lane,
            webrtc_media: false,
        },
        None,
    )
    .await
    .expect("connect");
    // A tab that is not a phone tab is refused.
    let refused = Arc::new(Recorder::default());
    let other = handle.open_surface(r#"{"tab":"s9"}"#.into(), refused.clone()).await;
    if let Ok(other) = other {
        refused.until("refused", |r| r.closed.lock().unwrap().is_some()).await;
        assert_eq!(refused.closed.lock().unwrap().as_deref(), Some("forbidden"));
        other.close();
    }
    let recorder = Arc::new(Recorder::default());
    let stream = handle.open_surface(r#"{"tab":"s12"}"#.into(), recorder.clone()).await.unwrap();
    recorder.until("welcome", |r| r.has("welcome", "encoder", "videotoolbox")).await;
    stream.send_message(r#"{"t":"rb.open","tab":"s12"}"#.into()).unwrap();
    recorder.until("rb.opened", |r| r.messages.lock().unwrap().iter().any(|m| m["t"] == "rb.opened")).await;
    recorder.until("a P-frame", |r| r.frames.lock().unwrap().iter().any(|f| !f.keyframe)).await;
    {
        let frames = recorder.frames.lock().unwrap();
        assert!(frames[0].keyframe);
        assert_eq!(&frames[0].access_unit[..5], &[0, 0, 0, 1, 0x67]);
    }
    let pointer = |kind: &str, x: f64, y: f64| {
        serde_json::json!({"e": "pointer", "surface": 0, "kind": kind, "x": x, "y": y, "button": 0,
            "buttons": 1, "click_count": 1, "modifiers": 0, "pointer_type": "touch"})
        .to_string()
    };
    stream.send_input(pointer("down", 0.5, 0.25), true).unwrap();
    stream.send_input(pointer("move", 0.5, 0.5), true).unwrap();
    stream.send_input(pointer("up", 0.5, 0.75), true).unwrap();
    stream
        .send_input(r#"{"e":"ime_commit","surface":0,"text":"héllo","replacement":null}"#.into(), true)
        .unwrap();
    stream.send_input(r#"{"e":"key","surface":0,"down":true,"code":"Enter","key":"Enter","text":"\r","unmodified_text":"\r","modifiers":0,"repeat":false,"location":0,"edit_commands":[]}"#.into(), true).unwrap();
    stream.send_input(r#"{"e":"button","surface":0,"button":"home"}"#.into(), true).unwrap();
    use serde_json::json;
    for _ in 0..400 {
        if fake_surface_source::has(&inputs, "button", "button", &json!("home")) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let lines: Vec<serde_json::Value> =
        inputs.lock().unwrap().iter().filter(|l| l["t"] != "visible").cloned().collect();
    assert_eq!(
        lines,
        vec![
            json!({"t": "touch", "phase": "began", "x": 0.5, "y": 0.25}),
            json!({"t": "touch", "phase": "moved", "x": 0.5, "y": 0.5}),
            json!({"t": "touch", "phase": "ended", "x": 0.5, "y": 0.75}),
            json!({"t": "text", "text": "héllo"}),
            json!({"t": "key", "key": "Enter", "down": true}),
            json!({"t": "button", "button": "home"}),
        ]
    );
    assert_eq!(stream.stats().video_track, video_lane);
    stream.close();
    recorder.until("closed", |r| r.closed.lock().unwrap().is_some()).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn surface_stream_over_webrtc() {
    surface_over(Transport::WebRtc, false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn surface_stream_over_rtp_inside_the_wireguard_tunnel() {
    surface_over(Transport::WireGuard, true).await;
}

/// The watchdog half of the 2026-10-24 freeze: a page that stops answering
/// (its host hung, or the channel stopped moving) left the phone showing the
/// last frame with every touch going nowhere. Input the host never
/// acknowledges now ends the stream as `stalled` within seconds, and the app
/// opens it again ("Reconnecting browser…").
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn input_the_page_never_acknowledges_ends_the_stream_as_stalled() {
    let rig = rig(Transport::WireGuard, true).await;
    let recorder = Arc::new(Recorder::default());
    let stream = rig
        .handle
        .open_browser(r#"{"tab":"s5","url":"https://example.com/"}"#.into(), recorder.clone())
        .await
        .unwrap();
    recorder.until("welcome", |r| r.has("welcome", "encoder", "fake")).await;
    // The stand-in host stops reading: nothing it gets is applied or answered.
    stream.send_message(r#"{"t":"rb.find","query":"hang"}"#.into()).unwrap();
    stream
        .send_input(
            r#"{"e":"pointer","surface":0,"kind":"down","x":10.0,"y":20.0,"button":0,"buttons":1,"click_count":1,"modifiers":0,"pointer_type":"touch"}"#
                .into(),
            true,
        )
        .unwrap();
    recorder.until("stalled", |r| r.closed.lock().unwrap().as_deref() == Some("stalled")).await;
}
