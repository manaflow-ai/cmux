//! Cloud session history bench: what offloading a home's chats frees and what opening one costs,
//! before and after, from one harness. Run it on a COPY of a home, never the live one: it archives
//! and offloads every chat in it.
//!
//! `cargo run --release -p acpmux --example cloud_history_bench -- HOME_COPY BLOB_DIR`
//!
//! With `CMUX_SESSION_CLOUD_ORIGIN` and `CMUX_SESSION_CLOUD_TOKEN` set, blobs go to that
//! cmux-platform `/v1/sync` store instead of `BLOB_DIR`. It prints one JSON line:
//! - disk bytes under `sessions/` before, archived (the existing cold archive), and offloaded;
//! - open time (every event of the chat read) p50/p95/max for a local chat, a locally archived
//!   chat (thaw), and an offloaded chat (fetch + decrypt + thaw).

use acpmux::store::{LocalStore, Store};
use cmux_session_cloud::{Cloud, seal::Key, store::BlobStore};
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

fn disk_bytes(path: &Path) -> u64 {
    use std::os::unix::fs::MetadataExt;
    let Ok(meta) = std::fs::symlink_metadata(path) else { return 0 };
    if meta.is_dir() {
        let entries =
            std::fs::read_dir(path).map(|d| d.flatten().collect::<Vec<_>>()).unwrap_or_default();
        meta.blocks() * 512 + entries.iter().map(|e| disk_bytes(&e.path())).sum::<u64>()
    } else {
        meta.blocks() * 512
    }
}

fn stats(mut ms: Vec<f64>) -> serde_json::Value {
    if ms.is_empty() {
        return serde_json::json!({"n": 0});
    }
    ms.sort_by(|a, b| a.total_cmp(b));
    let at = |q: f64| ms[((ms.len() as f64 - 1.0) * q).round() as usize];
    serde_json::json!({"n": ms.len(), "p50_ms": at(0.5), "p95_ms": at(0.95), "max_ms": ms[ms.len() - 1],
        "total_ms": ms.iter().sum::<f64>()})
}

/// Opens every chat in `ids` (reads all its events) and returns the times in ms.
fn open_all(store: &LocalStore, ids: &[String]) -> Vec<f64> {
    ids.iter()
        .map(|id| {
            let started = Instant::now();
            let events = Store::events(store, id, 0, usize::MAX)
                .unwrap_or_else(|error| panic!("open {id}: {error:#}"));
            std::hint::black_box(events.len());
            started.elapsed().as_secs_f64() * 1000.0
        })
        .collect()
}

/// Runs `each` over `ids` on every core (archiving is zstd level 19 plus an fsync per chat, so one
/// thread leaves the machine idle on fsync), printing progress to stderr; keeps the ids it said
/// yes to, in order.
fn par_filter(phase: &str, ids: &[String], each: impl Fn(&str) -> bool + Sync) -> Vec<String> {
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get());
    let next = std::sync::atomic::AtomicUsize::new(0);
    let done = std::sync::atomic::AtomicUsize::new(0);
    let kept: Vec<std::sync::Mutex<bool>> =
        ids.iter().map(|_| std::sync::Mutex::new(false)).collect();
    let started = Instant::now();
    std::thread::scope(|scope| {
        for _ in 0..threads {
            scope.spawn(|| {
                loop {
                    let i = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    let Some(id) = ids.get(i) else { break };
                    *kept[i].lock().unwrap() = each(id);
                    let n = done.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                    if n.is_multiple_of(100) || n == ids.len() {
                        eprintln!(
                            "{phase}: {n}/{} in {:.0}s",
                            ids.len(),
                            started.elapsed().as_secs_f64()
                        );
                    }
                }
            });
        }
    });
    ids.iter().zip(kept).filter_map(|(id, k)| k.into_inner().unwrap().then(|| id.clone())).collect()
}

/// Archives every chat in `ids`; returns the ones that were.
fn archive_all(store: &LocalStore, ids: &[String]) -> Vec<String> {
    par_filter("archive", ids, |id| match Store::stage_cold(store, id) {
        Ok(Some(staged)) => Store::commit_cold(store, id, staged).unwrap_or(false),
        _ => false,
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let usage = "usage: cloud_history_bench HOME_COPY BLOB_DIR";
    let home = std::path::PathBuf::from(args.first().expect(usage));
    let blobs = std::path::PathBuf::from(args.get(1).expect(usage));
    let sessions = home.join("sessions");
    let store = LocalStore::new(sessions.clone(), 1 << 20).expect("open the home copy");

    let (blob_store, store_kind): (Box<dyn BlobStore>, String) = match (
        std::env::var("CMUX_SESSION_CLOUD_ORIGIN"),
        std::env::var("CMUX_SESSION_CLOUD_TOKEN"),
    ) {
        (Ok(origin), Ok(token)) => (
            Box::new(
                cmux_session_cloud::store::HttpStore::new(&origin, &token).expect("http store"),
            ),
            "sync".into(),
        ),
        _ => (
            Box::new(cmux_session_cloud::store::FsStore::new(&blobs).expect("fs store")),
            "fs".into(),
        ),
    };
    Cloud::set(Some(Arc::new(Cloud {
        store: blob_store,
        key: Key::generate().expect("key"),
        root_prefix: std::env::var("CMUX_SESSION_CLOUD_ROOT_PREFIX").unwrap_or_default(),
    })));

    let mut ids: Vec<String> =
        Store::list(&store).expect("list").into_iter().map(|m| m.id).collect();
    ids.sort();
    // CLOUD_HISTORY_BENCH_CHATS=N measures the first N chats only, for a home too big to archive
    // inside a session's bound.
    if let Some(n) = std::env::var("CLOUD_HISTORY_BENCH_CHATS").ok().and_then(|v| v.parse().ok()) {
        ids.truncate(n);
    }
    eprintln!("{} chats", ids.len());
    let bytes_before = disk_bytes(&sessions);
    let local = open_all(&store, &ids);

    // The existing cold archive, then its open (thaw), then archived again for the offload.
    let started = Instant::now();
    let archived = archive_all(&store, &ids);
    let archive_ms = started.elapsed().as_millis() as u64;
    let bytes_archived = disk_bytes(&sessions);
    let thawed = open_all(&store, &archived);
    let archived = archive_all(&store, &archived);

    let started = Instant::now();
    let offload_errors = std::sync::atomic::AtomicUsize::new(0);
    let offloaded = par_filter("offload", &archived, |id| match Store::offload_cold(&store, id) {
        Ok(found) => found.is_some(),
        Err(error) => {
            offload_errors.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            eprintln!("offload {id}: {error:#}");
            false
        }
    });
    let offload_errors = offload_errors.into_inner();
    let offload_ms = started.elapsed().as_millis() as u64;
    // One GC root for the batch, as the daemon's pass will register it.
    let started = Instant::now();
    let rooted = Store::register_cloud_root(&store).expect("register the GC root");
    let root_ms = started.elapsed().as_millis() as u64;
    let bytes_offloaded = disk_bytes(&sessions);
    let fetched = open_all(&store, &offloaded);
    Cloud::set(None);

    let gib = |b: u64| (b as f64 / (1u64 << 30) as f64 * 1000.0).round() / 1000.0;
    println!(
        "{}",
        serde_json::json!({
            "host": std::fs::read_to_string("/etc/hostname").unwrap_or_default().trim(),
            "store": store_kind,
            "chats": ids.len(), "archived": archived.len(), "offloaded": offloaded.len(),
            "offload_errors": offload_errors,
            "disk": {
                "before_gib": gib(bytes_before), "archived_gib": gib(bytes_archived),
                "offloaded_gib": gib(bytes_offloaded),
                "freed_vs_before_gib": gib(bytes_before.saturating_sub(bytes_offloaded)),
                "freed_vs_archived_gib": gib(bytes_archived.saturating_sub(bytes_offloaded)),
                "blob_store_gib": gib(disk_bytes(&blobs)),
            },
            "archive_ms": archive_ms, "offload_ms": offload_ms, "root_ms": root_ms, "rooted": rooted,
            "open": {"local": stats(local), "archived_thaw": stats(thawed), "cloud_fetch": stats(fetched)},
        })
    );
}
