//! Harness rows for the relay cache (RFD 0142 R2 and R9): first content and resume after sleep
//! while the Mac is asleep, before (today: the relay holds nothing, the phone waits for the Mac)
//! and after (the relay's sealed snapshot and delta catch-up), idle and under duress.
//!
//! Run: `scripts/measure/relay-cache-open.sh` (or `cargo test -p cmux-mobile-host --release --test
//! relay_cache_rows -- --ignored --nocapture`). Prints one `RELAYCELL {json}` line per run and one
//! `RELAYROW {json}` per cell and arm (p50, p95, min, max, n, and how many runs got content).
//!
//! The rig, in one process: the fake backend's relay cache (`FakeOptions::relay_cache`, a mirror of
//! the Worker's `src/relay-cache.ts`); the Mac's real publisher (`relay_publish.rs`) writing to it
//! on loopback; the phone's real client (`cmux_mobile_link::relay_cache`) reading through
//! cmux-fault's seeded `lte` shaper (12/12 Mbit/s, 70 ms RTT, 0.5% loss), a new client per run so
//! every run pays its own TCP handshakes. Plain HTTP: a real cold open adds a TLS handshake.
//!
//! "Mac asleep" is the publisher stopped after its last put: nothing on the Mac side answers. The
//! before arm is the same rig with the cache off (the Worker's default, `503 relay_cache_off`): the
//! phone gets no content until the Mac wakes, so its rows are `null` with `content: 0/n`.
//!
//! Load, as the pair matrix defines it (`pair_matrix_ios_mac.rs`): idle = 5 chats of 20 turns;
//! duress = 50 chats, the measured one at 250x (5,000 turns), and the Mac streaming a 400-byte
//! record into it every 50 ms. A snapshot is the chat's newest 128 KiB (the open page). Cold open
//! under duress fetches all 50 chats' snapshots at once on the one shaped path and times the
//! measured one. Resume: the phone held the chat, slept 60 s while the Mac kept writing (idle: a
//! record every 5 s; duress: every 50 ms; coalesced into one delta per 250 ms), then the Mac slept
//! too; the phone wakes and asks the relay. The 60 s of writes are published back to back on a
//! synthetic clock (the relay's 10-minute expiry is not reached), not waited out.

use std::time::{Duration, Instant};

use cmux_fault::Trace;
use cmux_fault::shaper::{ProfileFile, Shaper};
use cmux_mobile_host::relay_publish::{Coalescer, RelayPublishConfig, RelayPublisher, Viewer};
use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::relay_cache::{
    FIRST_SCREEN_BYTES, MAX_BUDGET_BYTES, RelayCache, RelayCacheConfig, RelayCacheError, first_screen_stream,
};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_relay_snapshot::Floor;
use p256::SecretKey;
use p256::ecdsa::SigningKey;
use p256::elliptic_curve::rand_core::OsRng;
use serde_json::json;

const MAC: &str = "00000000-0000-4000-8000-0000000000aa";
const PHONE: &str = "00000000-0000-4000-8000-0000000000bb";
const PROFILE: &str = "lte";
const RECORD_BYTES: usize = 400;
const OPEN_BYTES: usize = 128 * 1024;
const SLEEP: Duration = Duration::from_secs(60);
const WINDOW: Duration = Duration::from_millis(250);
const COLD_RUNS: usize = 5;
const RESUME_RUNS: usize = 10;

fn runs(name: &str, default: usize) -> usize {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

struct Load {
    name: &'static str,
    chats: usize,
    measured_turns: usize,
    other_turns: usize,
    /// How often the Mac writes a record into the measured chat while the phone sleeps.
    every: Duration,
}

const IDLE: Load =
    Load { name: "idle", chats: 5, measured_turns: 20, other_turns: 20, every: Duration::from_secs(5) };
const DURESS: Load = Load {
    name: "duress",
    chats: 50,
    measured_turns: 5_000,
    other_turns: 20,
    every: Duration::from_millis(50),
};

fn record(seq: usize, role: &str) -> String {
    let text: String = format!("turn {seq} ").chars().cycle().take(RECORD_BYTES).collect();
    json!({"seq": seq, "role": role, "kind": "agent_message_chunk", "text": text}).to_string()
}

/// The chat's open page: its newest records, at most [`OPEN_BYTES`], as one JSON array.
fn open_page(records: &[String]) -> Vec<u8> {
    let mut size = 2;
    let mut start = records.len();
    while start > 0 && size + records[start - 1].len() < OPEN_BYTES {
        start -= 1;
        size += records[start].len() + 1;
    }
    format!("[{}]", records[start..].join(",")).into_bytes()
}

/// The chat's first screen: its newest records, at most [`FIRST_SCREEN_BYTES`].
fn first_screen(records: &[String]) -> Vec<u8> {
    let mut size = 2;
    let mut start = records.len();
    while start > 0 && size + records[start - 1].len() < FIRST_SCREEN_BYTES {
        start -= 1;
        size += records[start].len() + 1;
    }
    format!("[{}]", records[start..].join(",")).into_bytes()
}

fn chat(turns: usize) -> Vec<String> {
    (0..turns).flat_map(|t| [record(2 * t + 1, "user"), record(2 * t + 2, "assistant")]).collect()
}

fn stream_name(i: usize) -> String {
    format!("chat/{i}")
}

struct Rig {
    _server: FakeSignaling,
    shaper: Shaper,
    publisher: RelayPublisher,
    viewers: Vec<Viewer>,
    phone_key: SecretKey,
    /// The measured chat's records (chat 0), as the Mac holds them.
    measured: Vec<String>,
}

impl Rig {
    async fn start(cache_on: bool, load: &Load, seed: u64) -> Self {
        let server =
            FakeSignaling::start(FakeOptions { relay_cache: cache_on, ..FakeOptions::default() }).await;
        let upstream = server.base_url.trim_start_matches("http://").parse().expect("addr");
        let profile = ProfileFile::builtin().get(PROFILE).cloned().expect("lte profile");
        let shaper = Shaper::start(upstream, profile, seed, &Trace::new()).await.expect("shaper");
        let mac = RelayCache::new(
            ApiClient::new(&server.base_url, "user:me"),
            MAC,
            RelayCacheConfig { enabled: true },
        );
        // The publisher is on in both arms: with the relay's switch off its puts are refused (503),
        // as they would be against today's Worker.
        let publisher = RelayPublisher::new(
            mac,
            SigningKey::random(&mut OsRng),
            seed,
            RelayPublishConfig { enabled: true },
        );
        let phone_key = SecretKey::random(&mut OsRng);
        let viewers = vec![Viewer { device: PHONE.into(), key: phone_key.public_key() }];
        let measured = chat(load.measured_turns);
        publisher.publish_snapshot(&viewers, &stream_name(0), &open_page(&measured)).await;
        publisher.publish_first_screen(&viewers, &stream_name(0), &first_screen(&measured)).await;
        for i in 1..load.chats {
            publisher.publish_snapshot(&viewers, &stream_name(i), &open_page(&chat(load.other_turns))).await;
        }
        Self { _server: server, shaper, publisher, viewers, phone_key, measured }
    }

    /// The phone's client through the shaper, with no pooled connection.
    fn phone(&self) -> RelayCache {
        let base = format!("http://{}", self.shaper.addr());
        RelayCache::new(ApiClient::new(&base, "user:me"), PHONE, RelayCacheConfig { enabled: true })
    }

    /// The Mac writes for [`SLEEP`] at `every` (coalesced per [`WINDOW`]), then flushes and puts a
    /// fresh snapshot as it goes to sleep. Returns how many records it wrote.
    async fn mac_writes_then_sleeps(&mut self, every: Duration) -> usize {
        let stream = stream_name(0);
        let start = Instant::now();
        let mut coalescer = Coalescer::new(WINDOW);
        let count = (SLEEP.as_millis() / every.as_millis()) as usize;
        for i in 0..count {
            let seq = self.measured.len() + 1;
            let line = record(seq, "assistant");
            self.measured.push(line.clone());
            if let Some(batch) = coalescer.push(line.as_bytes(), start + every * (i as u32 + 1)) {
                self.publisher.publish_delta(&self.viewers, &stream, &batch).await;
            }
        }
        if let Some(batch) = coalescer.take() {
            self.publisher.publish_delta(&self.viewers, &stream, &batch).await;
        }
        self.publisher.publish_snapshot(&self.viewers, &stream, &open_page(&self.measured)).await;
        count
    }
}

fn cell(
    cell: &str,
    arm: &str,
    load: &str,
    run: usize,
    seed: u64,
    ms: Option<f64>,
    fields: serde_json::Value,
) {
    let mut line = json!({"cell": cell, "arm": arm, "load": load, "profile": PROFILE, "run": run, "seed": seed,
                          "ms": ms.map(|v| (v * 10.0).round() / 10.0)});
    if let (Some(line), Some(fields)) = (line.as_object_mut(), fields.as_object()) {
        line.extend(fields.clone());
    }
    println!("RELAYCELL {line}");
}

fn row(cell: &str, arm: &str, load: &str, runs: usize, samples: &mut [f64], note: &str) {
    samples.sort_by(f64::total_cmp);
    let pick = |q: f64| samples.get(((samples.len() as f64 - 1.0) * q).round() as usize).copied();
    let round = |v: Option<f64>| v.map(|v| (v * 10.0).round() / 10.0);
    println!(
        "RELAYROW {}",
        json!({"cell": cell, "arm": arm, "load": load, "profile": PROFILE, "n": runs,
               "content": format!("{}/{runs}", samples.len()),
               "p50_ms": round(pick(0.5)), "p95_ms": round(pick(0.95)),
               "min_ms": round(samples.first().copied()), "max_ms": round(samples.last().copied()), "note": note})
    );
}

/// One timed cold open of `stream`: the GET (connect, request, every byte) and the open, apart.
struct Timed {
    fetch_ms: f64,
    open_ms: f64,
    bytes: usize,
    plaintext: usize,
}

async fn timed_open(
    phone: &RelayCache,
    source: &p256::PublicKey,
    key: &SecretKey,
    stream: &str,
    floor: &mut Floor,
) -> Result<Option<Timed>, RelayCacheError> {
    let began = Instant::now();
    let Some((envelope, _)) = phone.snapshot(MAC, stream).await? else { return Ok(None) };
    let fetch_ms = began.elapsed().as_secs_f64() * 1000.0;
    let began = Instant::now();
    let opened = floor.open(key, source, stream, &envelope).map_err(RelayCacheError::Seal)?;
    let open_ms = began.elapsed().as_secs_f64() * 1000.0;
    Ok(Some(Timed { fetch_ms, open_ms, bytes: envelope.len(), plaintext: opened.plaintext.len() }))
}

/// The profile's rate, for the bytes-on-air share of a breakdown.
fn air_ms(bytes: usize) -> f64 {
    let profile = ProfileFile::builtin().get(PROFILE).cloned().expect("lte profile");
    let kbit = profile.down_kbit.max(1) as f64;
    bytes as f64 * 8.0 / kbit
}

/// The rest of the other chats' whole snapshots, fetched at once (duress only), as the app's list
/// does when it opens.
fn spawn_others(rig: &Rig, phone: &RelayCache, load: &Load) -> Vec<tokio::task::JoinHandle<()>> {
    let source = rig.publisher.source_key();
    (1..load.chats)
        .filter(|_| load.name == "duress")
        .map(|i| {
            let phone = phone.clone();
            let key = rig.phone_key.clone();
            tokio::spawn(async move {
                let mut floor = Floor::default();
                let _ = phone.cold_open(MAC, &source, &key, &stream_name(i), &mut floor).await;
            })
        })
        .collect()
}

/// `mac-asleep x cold-open`: the phone opens the app with no state; the Mac is asleep.
///
/// Arms: `before` (the relay holds nothing), `after` (the measured chat's whole snapshot, fetched
/// alongside every other chat's), `after-first-screen` (the measured chat's first-screen snapshot
/// first, alone; then every chat's whole snapshot at once). Each content run also prints where the
/// time went: `fetch_ms` (the shaped TCP handshake's round trip, the GET's round trip and every
/// byte; the shaper charges the handshake on the first data, so it is not timed apart), `air_ms` (the envelope's bytes at the profile's rate), `open_ms` (verify and decrypt).
async fn cold_open(load: &Load, arm: &str, n: usize) {
    let cache_on = arm != "before";
    let first_screen = arm == "after-first-screen";
    let mut samples = Vec::new();
    let mut whole_samples = Vec::new();
    for run in 0..n {
        let seed = 0x5eed_0000 + run as u64;
        let rig = Rig::start(cache_on, load, seed).await;
        let phone = rig.phone();
        let source = rig.publisher.source_key();
        let began = Instant::now();
        let mut floor = Floor::default();
        let (got, others, whole_ms) = if first_screen {
            let mut first_floor = Floor::default();
            let got = timed_open(
                &phone,
                &source,
                &rig.phone_key,
                &first_screen_stream(&stream_name(0)),
                &mut first_floor,
            )
            .await;
            let others = spawn_others(&rig, &phone, load);
            let whole = timed_open(&phone, &source, &rig.phone_key, &stream_name(0), &mut floor).await;
            let whole_ms = began.elapsed().as_secs_f64() * 1000.0;
            (got, others, whole.ok().flatten().map(|_| whole_ms))
        } else {
            let others = spawn_others(&rig, &phone, load);
            let got = timed_open(&phone, &source, &rig.phone_key, &stream_name(0), &mut floor).await;
            (got, others, None)
        };
        let ms = began.elapsed().as_secs_f64() * 1000.0;
        let ms = if first_screen {
            got.as_ref().ok().and_then(|g| g.as_ref()).map(|g| g.fetch_ms + g.open_ms).unwrap_or(ms)
        } else {
            ms
        };
        for other in others {
            let _ = other.await;
        }
        let (ms, fields) = match got {
            Ok(Some(t)) => {
                samples.push(ms);
                if let Some(w) = whole_ms {
                    whole_samples.push(w);
                }
                let round = |v: f64| (v * 10.0).round() / 10.0;
                (
                    Some(ms),
                    json!({"bytes": t.bytes, "plaintext": t.plaintext, 
                           "fetch_ms": round(t.fetch_ms), "air_ms": round(air_ms(t.bytes)), "open_ms": round(t.open_ms),
                           "whole_ms": whole_ms.map(round)}),
                )
            }
            Ok(None) => (None, json!({"why": "no snapshot"})),
            Err(RelayCacheError::RelayOff(code)) => {
                (None, json!({"why": format!("{code}: no content until the Mac wakes")}))
            }
            Err(error) => panic!("cold open: {error}"),
        };
        cell("mac-asleep x cold-open", arm, load.name, run, seed, ms, fields);
    }
    let note = match arm {
        "before" => "today: the relay holds nothing; first content waits for the Mac to wake",
        "after" => "first content from the relay's sealed whole snapshot (GET + open), Mac asleep",
        _ => {
            "first content from the relay's sealed first-screen snapshot (<= 12 KiB, one round trip), alone, then the rest"
        }
    };
    row("mac-asleep x cold-open", arm, load.name, n, &mut samples, note);
    if first_screen {
        row(
            "mac-asleep x cold-open (whole page)",
            arm,
            load.name,
            n,
            &mut whole_samples,
            "the measured chat's whole snapshot, fetched after its first screen with every other chat's",
        );
    }
}

/// `lte x resume-after-sleep x relay`: the phone held the chat, slept 60 s while the Mac kept
/// writing, then the Mac slept; the phone wakes and resumes.
async fn resume(load: &Load, cache_on: bool, n: usize) {
    let arm = if cache_on { "after" } else { "before" };
    let mut samples = Vec::new();
    for run in 0..n {
        let seed = 0x5eed_1000 + run as u64;
        let mut rig = Rig::start(cache_on, load, seed).await;
        let source = rig.publisher.source_key();
        // The phone's floor before it slept: it showed the chat at its open-page position.
        let mut floors = vec![(stream_name(0), Floor::at(rig.publisher.position(&stream_name(0))))];
        let held = rig.measured.len();
        let written = rig.mac_writes_then_sleeps(load.every).await;
        let phone = rig.phone();
        let began = Instant::now();
        let got = phone.resume_or_snapshot(MAC, &source, &rig.phone_key, &mut floors, MAX_BUDGET_BYTES).await;
        let ms = began.elapsed().as_secs_f64() * 1000.0;
        let (ms, fields) = match got {
            Ok(resumed) => {
                let applied: usize = resumed.surfaces.iter().map(|s| s.applied.len()).sum();
                let newest = rig.measured.last().map(String::as_bytes).unwrap_or_default();
                let shows_newest = resumed
                    .surfaces
                    .iter()
                    .any(|s| s.applied.last().is_some_and(|o| o.plaintext.ends_with(newest)))
                    || resumed.snapshots.iter().any(|o| o.plaintext.ends_with(&[newest, b"]"].concat()));
                assert!(shows_newest, "resume must reach the Mac's last record");
                samples.push(ms);
                (
                    Some(ms),
                    json!({"records_missed": written, "held": held, "deltas": applied,
                                  "via": if resumed.snapshots.is_empty() { "catch-up" } else { "catch-up cut, snapshot" },
                                  "bytes": resumed.bytes}),
                )
            }
            Err(RelayCacheError::RelayOff(code)) => (
                None,
                json!({"why": format!("{code}: no content until the Mac wakes"), "records_missed": written}),
            ),
            Err(error) => panic!("resume: {error}"),
        };
        cell("lte x resume-after-sleep x relay", arm, load.name, run, seed, ms, fields);
    }
    let note = if cache_on {
        "catch-up from the relay (cut surfaces take the newest snapshot), Mac asleep"
    } else {
        "today: the relay holds nothing; the new records wait for the Mac to wake"
    };
    row("lte x resume-after-sleep x relay", arm, load.name, n, &mut samples, note);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "harness rows: scripts/measure/relay-cache-open.sh"]
async fn relay_cache_rows() {
    let cold = runs("RELAYCACHE_COLD_RUNS", COLD_RUNS);
    let resumes = runs("RELAYCACHE_RESUME_RUNS", RESUME_RUNS);
    for load in [&IDLE, &DURESS] {
        for cache_on in [false, true] {
            resume(load, cache_on, resumes).await;
        }
        for arm in ["before", "after", "after-first-screen"] {
            cold_open(load, arm, cold).await;
        }
    }
}
