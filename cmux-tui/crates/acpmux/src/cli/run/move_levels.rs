//! Part of `transfer_live.rs`: the zstd level each link class learned, kept across moves.
//!
//! A move's pager climbs its pages' level on what it measures (`cmux_bytes::serial::Climb`), but
//! a climb that starts at level 3 every time spends its first pages relearning the same link, and
//! a move shorter than a few pages (the freeze's tail, a small chat) never climbs at all. So the
//! end of each copy keeps what it learned, by the target's link class, in `ACPMUX_HOME`'s
//! `move-levels.json`; the next copy over that class starts from it, and goes on climbing.
//!
//! Leo, 2026-11-25: "we have our own optimized for various cases/heuristics for compression. we
//! have our own optimized transport for various cases/heuristics. as fast as possible, as
//! syncable as possible, all that. and hill climbing there."
//!
//! A link class is the target's route: `ssh:HOST` (that host, through a forward) or `local` (a
//! socket on this machine). A route never seen takes its kind's latest (`ssh`, `local`): a new
//! ssh host is more like the last ssh host than like a fresh guess.

use crate::cli::run::move_end::Reach;
use cmux_bytes::serial::Learned;
use serde_json::{Value, json};
use std::path::PathBuf;

/// Classes kept at most: the oldest go first.
const KEEP_CLASSES: usize = 64;

/// The store (`ACPMUX_MOVE_LEVELS` for a test or the measure script, else `ACPMUX_HOME`'s).
fn path() -> PathBuf {
    match std::env::var_os("ACPMUX_MOVE_LEVELS") {
        Some(p) if !p.is_empty() => PathBuf::from(p),
        _ => crate::config::home().join("move-levels.json"),
    }
}

/// A target's link class, and its kind for a class never seen.
pub(crate) fn class_of(reach: Option<&Reach>) -> (String, &'static str) {
    match reach {
        Some(Reach::Ssh { host, .. }) => (format!("ssh:{host}"), "ssh"),
        Some(Reach::Socket { .. }) | None => ("local".to_owned(), "local"),
    }
}

fn read() -> Value {
    let bytes = std::fs::read(path()).unwrap_or_default();
    serde_json::from_slice::<Value>(&bytes).ok().filter(Value::is_object).unwrap_or(json!({}))
}

fn learned_of(v: &Value) -> Option<Learned> {
    let level = v.get("level")?.as_i64()? as i32;
    let link = v.get("linkBytesPerSec")?.as_f64()?;
    let cpu = v.get("cpu")?.as_f64()?;
    ((1..=19).contains(&level) && link > 0.0 && cpu > 0.0).then_some(Learned { level, link, cpu })
}

/// What `class` learned, else its `kind`'s latest.
pub(crate) fn recall(class: &str, kind: &str) -> Option<Learned> {
    recall_in(&read(), class, kind)
}

pub(super) fn recall_in(store: &Value, class: &str, kind: &str) -> Option<Learned> {
    let classes = store.get("classes")?;
    if let Some(l) = classes.get(class).and_then(learned_of) {
        return Some(l);
    }
    store.get("latest")?.get(kind).and_then(learned_of)
}

/// Keeps what a copy over `class` learned. A failed write costs only the next move's first
/// pages: it is not reported.
pub(crate) fn keep(class: &str, kind: &str, learned: Learned, now_ms: u64) {
    let store = kept_in(read(), class, kind, learned, now_ms);
    let path = path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(bytes) = serde_json::to_vec_pretty(&store) {
        let _ = crate::config::write_atomic_unsynced(&path, &bytes);
    }
}

pub(super) fn kept_in(mut store: Value, class: &str, kind: &str, l: Learned, now_ms: u64) -> Value {
    if !store.is_object() {
        store = json!({});
    }
    let entry = json!({"level": l.level, "linkBytesPerSec": l.link.round(), "cpu": l.cpu,
                       "at": now_ms});
    let classes = store.as_object_mut().unwrap().entry("classes").or_insert_with(|| json!({}));
    if !classes.is_object() {
        *classes = json!({});
    }
    let map = classes.as_object_mut().unwrap();
    let seen = map.get(class).and_then(|e| e.get("copies")).and_then(Value::as_u64).unwrap_or(0);
    let mut entry_with = entry.clone();
    entry_with["copies"] = json!(seen + 1);
    map.insert(class.to_owned(), entry_with);
    while map.len() > KEEP_CLASSES {
        let oldest = map
            .iter()
            .min_by_key(|(_, e)| e.get("at").and_then(Value::as_u64).unwrap_or(0))
            .map(|(k, _)| k.clone());
        match oldest {
            Some(k) => map.remove(&k),
            None => break,
        };
    }
    let latest = store.as_object_mut().unwrap().entry("latest").or_insert_with(|| json!({}));
    if !latest.is_object() {
        *latest = json!({});
    }
    latest[kind] = entry;
    store
}
