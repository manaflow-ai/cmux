//! How long the Mac takes from a phone's offer (`wg-init`) to its answer
//! (`wg-resp`), warm, after a wake and after a network change, with a slow
//! `GET /v1/ice` (it answers after 2 s, as a slow Worker or TURN API) and a
//! STUN server that never answers. "before" turns on the measurement
//! switches that restore the old waits (a wake drops the ICE servers; the
//! answer waits out the STUN gather); "after" is the default.
//!
//! Prints one `NETCOND {...}` line per run and a p50/p95 summary per case.

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_mobile_host::auth::{TokenSource, Tokens};
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{DialOptions, LinkConfig, SignalingClient, Timeline, TransportKind};

const ICE_DELAY: Duration = Duration::from_secs(2);

/// The measurement switches are process-wide: one test at a time.
static SWITCHES: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn runs() -> usize {
    std::env::var("ANSWER_LATENCY_RUNS").ok().and_then(|v| v.parse().ok()).unwrap_or(20)
}

/// A STUN server that reads every request and answers none.
async fn silent_stun() -> (String, tokio::task::JoinHandle<()>) {
    let socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let addr = socket.local_addr().unwrap().to_string();
    let task = tokio::spawn(async move {
        let mut buffer = [0u8; 1500];
        while socket.recv_from(&mut buffer).await.is_ok() {}
    });
    (addr, task)
}

/// A STUN server that maps every request to `mapped` (a public-looking
/// reflexive address, so it is not one of the host endpoints).
async fn mapping_stun(mapped: std::net::SocketAddrV4) -> (String, tokio::task::JoinHandle<()>) {
    let socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let addr = socket.local_addr().unwrap().to_string();
    let task = tokio::spawn(async move {
        let mut buffer = [0u8; 1500];
        while let Ok((len, from)) = socket.recv_from(&mut buffer).await {
            if len < 20 {
                continue;
            }
            let mut reply = Vec::with_capacity(32);
            reply.extend_from_slice(&0x0101u16.to_be_bytes());
            reply.extend_from_slice(&12u16.to_be_bytes());
            reply.extend_from_slice(&0x2112_A442u32.to_be_bytes());
            reply.extend_from_slice(&buffer[8..20]);
            reply.extend_from_slice(&0x0020u16.to_be_bytes());
            reply.extend_from_slice(&8u16.to_be_bytes());
            reply.extend_from_slice(&[0, 1]);
            reply.extend_from_slice(&(mapped.port() ^ 0x2112).to_be_bytes());
            reply.extend_from_slice(&(u32::from(*mapped.ip()) ^ 0x2112_A442).to_be_bytes());
            let _ = socket.send_to(&reply, from).await;
        }
    });
    (addr, task)
}

struct Rig {
    server: FakeSignaling,
    ice: IceSource,
    phone: SignalingClient,
    mac_id: String,
    _dir: tempfile::TempDir,
}

async fn rig(stun: &str) -> Rig {
    let server = FakeSignaling::start(FakeOptions {
        ice_delay: ICE_DELAY,
        ice_stun: Some(stun.to_owned()),
        ..FakeOptions::default()
    })
    .await;
    let dir = tempfile::tempdir().unwrap();
    let services = Arc::new(ServiceConfig {
        tui_socket_dir: dir.path().to_owned(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![],
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        pairing: None,
        agent_tab_host: None,
        uploads_dir: dir.path().join("uploads"),
        chief_socket: None,
        browser: cmux_mobile_host::browser::BrowserConfig::new(None, 1),
        surface: cmux_mobile_host::surface::SurfaceConfig::new(None, 1),
    });
    let tokens = Arc::new(Tokens::new(TokenSource::Access("user:alice".into())));
    let ice = IceSource::api(server.base_url.clone(), None, tokens);
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    tokio::spawn(serve_signaling(
        mac,
        AnswerContext {
            owner_user_id: "alice".into(),
            services,
            ice: ice.clone(),
            include_loopback: true,
            exclude_cgnat: false,
            mailbox: None,
            session_exposure: None,
        },
    ));
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    Rig { server, ice, phone, mac_id, _dir: dir }
}

/// Mac side (offer forwarded to the Mac, its answer back at the server) and
/// phone side (`wg_init_sent` to `wg_resp_received`), in milliseconds.
struct Sample {
    mac_ms: f64,
    phone_ms: f64,
    connected: cmux_mobile_link::Connected,
}

async fn dial(rig: &Rig) -> Sample {
    let timeline = Timeline::new();
    let options = DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(20),
        timeline: timeline.clone(),
        ..DialOptions::default()
    };
    let connected = cmux_mobile_link::dial::connect(
        &rig.phone,
        &rig.mac_id,
        TransportKind::WireGuard,
        &options,
        LinkConfig::default(),
    )
    .await
    .expect("the phone connects");
    let session = &connected.session_id;
    let offer = rig.server.forwarded_at(session, "wg-init").expect("offer forwarded");
    let answer = rig.server.forwarded_at(session, "wg-resp").expect("answer forwarded");
    let phone = timeline.get("wg_resp_received").unwrap() - timeline.get("wg_init_sent").unwrap();
    Sample {
        mac_ms: answer.duration_since(offer).as_secs_f64() * 1000.0,
        phone_ms: phone.as_secs_f64() * 1000.0,
        connected,
    }
}

fn percentile(values: &[f64], p: f64) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let rank = ((p / 100.0) * sorted.len() as f64).ceil() as usize;
    sorted[rank.clamp(1, sorted.len()) - 1]
}

#[derive(Clone, Copy, Debug)]
enum Profile {
    Warm,
    Wake,
    NetworkChange,
}

impl Profile {
    fn name(self) -> &'static str {
        match self {
            Self::Warm => "warm",
            Self::Wake => "wake",
            Self::NetworkChange => "network-change",
        }
    }
}

fn set_phase(before: bool) {
    cmux_mobile_host::host::set_fetch_after_wake(before);
    cmux_mobile_link::dial::wireguard::set_answer_after_gather(before);
}

async fn measure(profile: Profile, before: bool, runs: usize, summary: &mut Vec<String>) {
    set_phase(before);
    let phase = if before { "before" } else { "after" };
    let (stun, _stun_task) = silent_stun().await;
    let rig = rig(&stun).await;
    // Warm the cache: the first answer of a process has nothing cached and
    // waits for `GET /v1/ice` either way.
    drop(dial(&rig).await.connected);
    let (mut mac, mut phone) = (Vec::new(), Vec::new());
    let mut previous: Option<cmux_mobile_link::Connected> = None;
    for run in 0..runs {
        match profile {
            Profile::Warm => {}
            Profile::Wake => rig.ice.invalidate(),
            Profile::NetworkChange => {
                // hostd on a network change: the live tunnels roam and the
                // ICE servers go stale.
                rig.ice.invalidate();
                cmux_mobile_link::dial::wireguard::network_changed().await;
            }
        }
        drop(previous.take());
        let sample = dial(&rig).await;
        for (surface, value) in [("mac-answer", sample.mac_ms), ("phone-dial", sample.phone_ms)] {
            println!(
                "NETCOND {}",
                serde_json::json!({
                    "surface": surface,
                    "profile": profile.name(),
                    "phase": phase,
                    "metric": "offer_to_answer_ms",
                    "value": (value * 10.0).round() / 10.0,
                    "run": run,
                    "seed": 0,
                    "ice_delay_ms": ICE_DELAY.as_millis() as u64,
                    "stun": "silent",
                })
            );
        }
        mac.push(sample.mac_ms);
        phone.push(sample.phone_ms);
        previous = Some(sample.connected);
    }
    drop(previous);
    let line = format!(
        "| {} | {} | {:.0} | {:.0} | {:.0} | {:.0} |",
        profile.name(),
        phase,
        percentile(&mac, 50.0),
        percentile(&mac, 95.0),
        percentile(&phone, 50.0),
        percentile(&phone, 95.0),
    );
    println!("SUMMARY {line}");
    summary.push(line);
}

/// Before/after over `ANSWER_LATENCY_RUNS` runs (default 20) per case. The
/// "after" bounds: no answer waits on `GET /v1/ice` once anything was
/// fetched, nor on a silent STUN server.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn offer_to_answer_before_and_after() {
    let _switches = SWITCHES.lock().await;
    let runs = runs();
    let mut summary = Vec::new();
    for profile in [Profile::Warm, Profile::Wake, Profile::NetworkChange] {
        for before in [true, false] {
            measure(profile, before, runs, &mut summary).await;
        }
    }
    set_phase(false);
    println!("| profile | phase | mac p50 ms | mac p95 ms | phone p50 ms | phone p95 ms |");
    println!("|---|---|---|---|---|---|");
    for line in &summary {
        println!("{line}");
    }
    // The after rows: far under the 1.5 s STUN wait and the 2 s ICE fetch.
    for line in summary.iter().filter(|line| line.contains("| after |")) {
        let p95: f64 = line.split('|').nth(4).unwrap().trim().parse().unwrap();
        assert!(p95 < 750.0, "an answer waited: {line}");
    }
}

/// The answer went out with host endpoints only; the reflexive endpoint
/// STUN finds comes after it, announced to the phone, and the Mac's own
/// record of what it offered has it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_reflexive_endpoint_follows_the_answer() {
    let _switches = SWITCHES.lock().await;
    set_phase(false);
    let mapped: std::net::SocketAddrV4 = "198.51.100.7:4242".parse().unwrap();
    let (stun, _stun_task) = mapping_stun(mapped).await;
    let rig = rig(&stun).await;
    drop(dial(&rig).await.connected);
    let sample = dial(&rig).await;
    let session = sample.connected.session_id.clone();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let endpoints =
            cmux_mobile_link::dial::wireguard::session_endpoints(&session, false).unwrap_or_default();
        if endpoints.contains(&mapped.to_string()) {
            break;
        }
        assert!(Instant::now() < deadline, "no reflexive endpoint announced: {endpoints:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    drop(sample.connected);
}
