//! The `bundle` service against the old `upload` and `file` over cmux-fault's `lte` profile (12 Mbit/s
//! each way, 70 ms RTT, 0.5% loss), one seed per run: a phone link through the Shaper to a link served
//! by hostd's own `services::serve`. Rows: first send, re-sent attachment, open when the phone holds it.
//!
//! `cargo test --release -p cmux-mobile-link-ffi --test bundle_lte -- --ignored --nocapture`

use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_fault::Trace;
use cmux_fault::shaper::{ProfileFile, Shaper};
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::services::Peer;
use cmux_mobile_link::bundle_link::cmux_bundle::store::MemStore;
use cmux_mobile_link::bundle_link::cmux_bundle::sync::Sender;
use cmux_mobile_link::bundle_link::cmux_bundle::{Kind, PairKey};
use cmux_mobile_link::link::{Link, LinkConfig, Role};
use cmux_mobile_link_ffi::bundle::{self, Outcome};
use tokio::net::{TcpListener, TcpStream};

const SIZE: usize = 3 << 20;
const SEEDS: u64 = 5;

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

struct Rig {
    _dirs: tempfile::TempDir,
    _shaper: Shaper,
    root: std::path::PathBuf,
    link: Link,
}

async fn rig(profile: &str, seed: u64) -> Rig {
    let dirs = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dirs.path()).unwrap().join("work");
    std::fs::create_dir_all(&root).unwrap();
    let config = Arc::new(ServiceConfig {
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
    });
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let link_profile = ProfileFile::builtin().get(profile).cloned().expect("profile");
    let shaper =
        Shaper::start(listener.local_addr().unwrap(), link_profile, seed, &Trace::new()).await.unwrap();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        stream.set_nodelay(true).unwrap();
        let mac = Link::new(stream, Role::Mac, LinkConfig::default(), None);
        let auth = Arc::new(cmux_mobile_host::pairing::LinkAuth::default());
        let peer = Peer {
            device_id: "phone-1".into(),
            session_id: uuid::Uuid::new_v4().to_string(),
            video: None,
            session_exposure: None,
            route: None,
            path: None,
            viewport: None,
        };
        while let Some(incoming) = mac.accept().await {
            tokio::spawn(cmux_mobile_host::services::serve(
                Arc::clone(&config),
                peer.clone(),
                Arc::clone(&auth),
                incoming,
            ));
        }
    });
    let stream = TcpStream::connect(shaper.addr()).await.unwrap();
    stream.set_nodelay(true).unwrap();
    let link = Link::new(stream, Role::Phone, LinkConfig::default(), None);
    Rig { _dirs: dirs, _shaper: shaper, root, link }
}

fn done(outcome: Outcome) -> cmux_mobile_link_ffi::bundle::FileTransfer {
    match outcome {
        Outcome::Done(transfer) => transfer,
        Outcome::Fallback(_) => panic!("fell back"),
    }
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[v.len() / 2]
}

#[derive(Default)]
struct Row {
    ms: Vec<f64>,
    bytes: u64,
}

impl Row {
    fn add(&mut self, d: Duration, bytes: u64) {
        self.ms.push(ms(d));
        self.bytes = bytes;
    }
    fn show(&self) -> String {
        let mut sorted = self.ms.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        format!(
            "{} B, median {:.0} ms (min {:.0}, max {:.0})",
            self.bytes,
            median(self.ms.clone()),
            sorted[0],
            sorted[sorted.len() - 1]
        )
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a hand-run measurement"]
async fn bundle_against_upload_and_file_on_lte() {
    // The Mac's and the phone's CPU cost alone: chunk, hash, compress and seal 3 MiB.
    let data = photo(SIZE, 1);
    let key = PairKey::derive(&[9; 32]);
    let mut seal = Vec::new();
    for _ in 0..5 {
        let started = Instant::now();
        let sender = Sender::new(&key, Kind::Attachment, &data, &mut MemStore::default()).unwrap();
        seal.push(ms(started.elapsed()));
        std::hint::black_box(sender.offer());
    }
    println!("cpu: Sender::new over {SIZE} B: median {:.1} ms", median(seal));

    let profile = std::env::var("BUNDLE_PROFILE").unwrap_or_else(|_| "lte".into());
    let (mut upload, mut first, mut resend, mut file, mut held, mut keyed) =
        (Row::default(), Row::default(), Row::default(), Row::default(), Row::default(), Row::default());
    for seed in 1..=SEEDS {
        let rig = rig(&profile, seed).await;
        let phone = tempfile::tempdir().unwrap();
        let source = phone.path().join("shot.png");
        std::fs::write(&source, photo(SIZE, 7 + seed)).unwrap();
        let store = phone.path().join("bundles/mac");
        let cwd = rig.root.to_str().unwrap().to_owned();
        // Warm the link (its window) the same way for every row.
        bundle::upload_plain(&rig.link, &source, "warm.png", &cwd).await.unwrap();

        let started = Instant::now();
        let plain = bundle::upload_plain(&rig.link, &source, "plain.png", &cwd).await.unwrap();
        upload.add(started.elapsed(), plain.sent_bytes);

        let started = Instant::now();
        let sent = done(bundle::upload_bundle(&rig.link, &source, "a.png", &cwd, &store).await.unwrap());
        first.add(started.elapsed(), sent.sent_bytes + sent.received_bytes);

        let started = Instant::now();
        let again = done(bundle::upload_bundle(&rig.link, &source, "b.png", &cwd, &store).await.unwrap());
        resend.add(started.elapsed(), again.sent_bytes + again.received_bytes);

        let other = phone.path().join("other.png");
        std::fs::write(&other, photo(SIZE, 100 + seed)).unwrap();
        let started = Instant::now();
        let sent = done(bundle::upload_bundle(&rig.link, &other, "c.png", &cwd, &store).await.unwrap());
        keyed.add(started.elapsed(), sent.sent_bytes + sent.received_bytes);

        let on_mac = rig.root.join("shot-on-mac.png");
        std::fs::copy(&source, &on_mac).unwrap();
        let dest = phone.path().join("open/plain.png");
        let started = Instant::now();
        let opened = bundle::open_plain(&rig.link, on_mac.to_str().unwrap(), &dest).await.unwrap();
        file.add(started.elapsed(), opened.received_bytes);

        let dest = phone.path().join("open/held.png");
        let started = Instant::now();
        let opened =
            done(bundle::open_bundle(&rig.link, on_mac.to_str().unwrap(), &dest, &store).await.unwrap());
        held.add(started.elapsed(), opened.sent_bytes + opened.received_bytes);
        assert_eq!(std::fs::read(&dest).unwrap(), std::fs::read(&source).unwrap());
        assert!(Path::new(&again.path).exists());
    }
    println!("profile {profile}, {SEEDS} seeds, {SIZE} B incompressible:");
    println!(
        "scoreboard: first send (first bundle to this Mac): upload {} | bundle {}",
        upload.show(),
        first.show()
    );
    println!(
        "scoreboard: first send (new file, key cached): upload {} | bundle {}",
        upload.show(),
        keyed.show()
    );
    println!("scoreboard: re-sent attachment: upload {} | bundle {}", upload.show(), resend.show());
    println!("scoreboard: attachment open (phone holds it): file {} | bundle {}", file.show(), held.show());
}
