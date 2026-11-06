//! The chat activity cost with a long history: 9,000 closed sessions and 50 live ones, read by 8
//! chats watchers on every one-chat change batch while another thread resolves sessions (a peer
//! notice's lookup). The output supplies the PR's before/after table.

use super::*;
use crate::config::Config;
use crate::hub::peer_snapshot::thread_allocations;
use crate::store::{MemoryStore, Store};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Barrier};
use std::time::{Duration, Instant};

const CLOSED: usize = 9_000;
const LIVE: usize = 50;
const WATCHERS: usize = 8;
const BATCHES: usize = 20;

fn scale_hub() -> Arc<Hub> {
    let store = MemoryStore::default();
    for n in 0..CLOSED + LIVE {
        let live = n >= CLOSED;
        // Every tenth closed session continues the chat before it; a third were started by a
        // live session's agent.
        let chat = if !live && n % 10 == 9 { n - 1 } else { n };
        let mut row = json!({"schema": crate::store::META_SCHEMA, "id": format!("s-{n:05}"),
            "name": format!("s-{n:05}"), "harness": "claude", "family": "claude",
            "agentSessionId": format!("chat-{chat:05}"), "cwd": "/nonexistent",
            "status": if !live { "closed" } else if n % 5 == 0 { "waiting" } else { "idle" },
            "createdAt": 1, "updatedAt": n + 1, "unread": n % 7 == 0,
            "preview": "A short synthetic reply\nover two lines",
            "configOptions": [{"payload": "x".repeat(2_048)}]});
        if !live && n % 3 == 0 {
            let parent = CLOSED + n % LIVE;
            row.set("tags", json!({"spawnedBy": {"value": format!("s-{parent:05}")}}));
        }
        store.save(&serde_json::from_value(row).unwrap()).unwrap();
    }
    Hub::new(Config::default(), Box::new(store))
}

fn process_cpu() -> Duration {
    let mut value = std::mem::MaybeUninit::<libc::timespec>::uninit();
    assert_eq!(
        unsafe { libc::clock_gettime(libc::CLOCK_PROCESS_CPUTIME_ID, value.as_mut_ptr()) },
        0
    );
    let value = unsafe { value.assume_init() };
    Duration::new(u64::try_from(value.tv_sec).unwrap(), u32::try_from(value.tv_nsec).unwrap())
}

/// What one watcher does with a one-chat batch: the activity, then the chat's value decorated.
fn one_watcher(hub: &Hub, batch: &Arc<Vec<SeqChange>>, n: usize) -> Value {
    let activity = hub.chat_activity_for_batch(batch);
    let mut chat = json!({"key": format!("claude-code:chat-{:05}", n % (CLOSED + LIVE))});
    activity.decorate(&mut chat);
    chat
}

fn percentile(sorted: &[Duration], p: f64) -> f64 {
    let at = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted.get(at).map_or(0.0, |d| d.as_secs_f64() * 1e6)
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "manual chat activity measurement"]
fn measure_chat_activity_9000_closed_8_watchers() {
    let hub = scale_hub();
    assert_eq!(hub.sessions().len(), CLOSED + LIVE);
    // Same answers at base and head: a closed chat keeps its preview and parent, a waiting live
    // one needs input.
    let initial = Arc::new(Vec::new());
    let closed = one_watcher(&hub, &initial, 3);
    assert_eq!(closed["preview"], json!("A short synthetic reply over two lines"));
    assert_eq!(closed["parent"], json!(format!("claude-code:chat-{:05}", CLOSED + 3)));

    // One watcher, one batch: time, CPU and allocations on this thread.
    let rounds = 20;
    let (start, cpu) = (Instant::now(), process_cpu());
    let mut allocations = 0;
    let stable = Arc::new(Vec::new());
    for n in 0..rounds {
        let (value, made) = thread_allocations(|| one_watcher(&hub, &stable, n * 97));
        std::hint::black_box(value);
        allocations += made;
    }
    let wall = start.elapsed().as_secs_f64() * 1000.0 / rounds as f64;
    let cpu = (process_cpu() - cpu).as_secs_f64() * 1000.0 / rounds as f64;
    eprintln!(
        "chat activity, stable cache hit, 1 watcher: {wall:.3} wall ms/batch, {cpu:.3} CPU ms/batch, {} allocations/batch",
        allocations / rounds
    );

    // 8 watchers on every batch, as `forward` runs one task per chats-watching connection, while
    // a ninth thread resolves a live session by id over and over (the sessions map lock a peer
    // notice takes).
    let stop = Arc::new(AtomicBool::new(false));
    let contender = {
        let (hub, stop) = (hub.clone(), stop.clone());
        std::thread::spawn(move || {
            let mut waits = Vec::new();
            let id = format!("s-{CLOSED:05}");
            while !stop.load(Ordering::Relaxed) {
                let start = Instant::now();
                std::hint::black_box(hub.resolve(&id).unwrap());
                waits.push(start.elapsed());
                std::thread::yield_now();
            }
            waits
        })
    };
    let barrier = Arc::new(Barrier::new(WATCHERS + 1));
    let changes = Arc::new(Vec::new());
    let watchers: Vec<_> = (0..WATCHERS)
        .map(|w| {
            let (hub, barrier, changes) = (hub.clone(), barrier.clone(), changes.clone());
            std::thread::spawn(move || {
                for batch in 0..BATCHES {
                    barrier.wait();
                    std::hint::black_box(one_watcher(&hub, &changes, batch * 31 + w));
                    barrier.wait();
                }
            })
        })
        .collect();
    let mut batches = Vec::new();
    let cpu = process_cpu();
    for _ in 0..BATCHES {
        let start = Instant::now();
        // A mux activity record is the one-chat mutation that invalidates the batch. The
        // benchmark uses the cache's production mutation hook so the watchers see its version.
        hub.chat_activity_cache.note(&format!("s-{CLOSED:05}"), "status", false);
        barrier.wait();
        barrier.wait();
        batches.push(start.elapsed());
    }
    let cpu = (process_cpu() - cpu).as_secs_f64() * 1000.0 / BATCHES as f64;
    for watcher in watchers {
        watcher.join().unwrap();
    }
    stop.store(true, Ordering::Relaxed);
    let mut waits = contender.join().unwrap();
    batches.sort();
    waits.sort();
    eprintln!(
        "chat activity, {WATCHERS} watchers, invalidated batch: batch p50 {:.3} ms, p99 {:.3} ms, {cpu:.3} CPU ms/batch",
        percentile(&batches, 0.5) / 1000.0,
        percentile(&batches, 0.99) / 1000.0,
    );
    eprintln!(
        "session resolve under {WATCHERS} watchers: p50 {:.1} us, p99 {:.1} us, max {:.1} us, n {}",
        percentile(&waits, 0.5),
        percentile(&waits, 0.99),
        percentile(&waits, 1.0),
        waits.len(),
    );
}
