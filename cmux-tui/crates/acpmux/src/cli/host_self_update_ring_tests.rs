//! The config ring tick on a fake file server: applied, unchanged, a replayed older file,
//! a bad signature and a missing file, each leaving the applied state where it must be.

use std::collections::HashMap;

use base64::Engine as _;
use futures::future::BoxFuture;
use ring::rand::SystemRandom;
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::{Value, json};

use super::*;
use cmux_signed_envelope::key_id;

const RING: &str = "feat-cmux-next";
const NOW: u64 = 1_795_400_000;

struct Files(HashMap<String, Vec<u8>>);

impl Fetch for Files {
    fn get<'a>(&'a self, url: &'a str, max: usize) -> BoxFuture<'a, Result<Vec<u8>, String>> {
        let body = match self.0.get(url) {
            Some(body) if body.len() <= max => Ok(body.clone()),
            Some(_) => Err(format!("the body is above the {max} byte limit")),
            None => Err("the server answered 404".to_owned()),
        };
        Box::pin(async move { body })
    }
}

fn key_pair() -> Ed25519KeyPair {
    let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
    Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap()
}

fn trust(pair: &Ed25519KeyPair) -> Vec<Key> {
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    vec![(key_id(&raw), raw)]
}

fn ring_file(pair: &Ed25519KeyPair, seq: u64, fast_resume: bool) -> Files {
    let payload = json!({
        "schema": 1, "purpose": "cmux-config-ring", "ring": RING, "seq": seq,
        "issued_at": NOW - 60, "expires_at": NOW + 86_400,
        "flags": {"chat.fast_resume": fast_resume, "update.rollout_pct": 25},
    });
    let bytes = serde_json::to_vec(&payload).unwrap();
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    let body = serde_json::to_vec(&json!({
        "schema": 1,
        "payload": b64.encode(&bytes),
        "signatures": [{"key_id": key_id(&raw), "sig": b64.encode(pair.sign(&bytes).as_ref())}],
    }))
    .unwrap();
    Files(HashMap::from([(ring_url(RING), body)]))
}

fn run(home: &Path, files: &Files, keys: &[Key]) -> RingOutcome {
    futures::executor::block_on(tick(home, files, keys, RING, NOW))
}

#[test]
fn the_url_is_the_rings_folder_beside_the_channels() {
    assert_eq!(ring_url(RING), "https://files.cmux.com/cmux-tui/rings/feat-cmux-next.json");
}

#[test]
fn a_newer_signed_ring_is_applied_and_kept() {
    let home = tempfile::tempdir().unwrap();
    let pair = key_pair();
    let outcome = run(home.path(), &ring_file(&pair, 3, false), &trust(&pair));
    assert_eq!(outcome, RingOutcome::Applied { seq: 3, flags: 2 });
    let kept = applied(home.path(), RING).unwrap();
    assert_eq!(kept.seq, 3);
    assert_eq!(kept.applied_at, NOW);
    assert_eq!(kept.flags.get("chat.fast_resume"), Some(&Value::Bool(false)));
    assert_eq!(kept.flags.get("update.rollout_pct"), Some(&json!(25.0)));

    // The same file on the next tick changes nothing.
    let again = run(home.path(), &ring_file(&pair, 3, false), &trust(&pair));
    assert_eq!(again, RingOutcome::Unchanged { seq: 3 });
}

#[test]
fn a_replayed_older_ring_never_turns_a_flag_back() {
    let home = tempfile::tempdir().unwrap();
    let pair = key_pair();
    run(home.path(), &ring_file(&pair, 5, false), &trust(&pair));
    let replay = run(home.path(), &ring_file(&pair, 4, true), &trust(&pair));
    assert!(
        matches!(replay, RingOutcome::Refused(ref why) if why.contains("replayed")),
        "{replay:?}"
    );
    let kept = applied(home.path(), RING).unwrap();
    assert_eq!((kept.seq, kept.flags.get("chat.fast_resume")), (5, Some(&Value::Bool(false))));
}

#[test]
fn an_untrusted_signature_leaves_the_applied_ring() {
    let home = tempfile::tempdir().unwrap();
    let pair = key_pair();
    run(home.path(), &ring_file(&pair, 5, false), &trust(&pair));
    let forged = run(home.path(), &ring_file(&key_pair(), 9, true), &trust(&pair));
    assert!(matches!(forged, RingOutcome::Refused(_)), "{forged:?}");
    assert_eq!(applied(home.path(), RING).unwrap().seq, 5);
}

#[test]
fn no_published_ring_is_a_note_and_keeps_nothing() {
    let home = tempfile::tempdir().unwrap();
    let outcome = run(home.path(), &Files(HashMap::new()), &[]);
    assert!(matches!(outcome, RingOutcome::NotRead(_)), "{outcome:?}");
    assert_eq!(outcome.line(RING), None);
    assert!(applied(home.path(), RING).is_none());
}

#[test]
fn the_shipped_keys_are_the_rings_keys() {
    assert!(!cmux_signed_envelope::config_ring::trusted_keys().is_empty());
}

fn ring_with(pair: &Ed25519KeyPair, seq: u64, flags: Value) -> Files {
    let payload = json!({
        "schema": 1, "purpose": "cmux-config-ring", "ring": RING, "seq": seq,
        "issued_at": NOW - 60, "expires_at": NOW + 86_400, "flags": flags,
    });
    let bytes = serde_json::to_vec(&payload).unwrap();
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    let body = serde_json::to_vec(&json!({
        "schema": 1,
        "payload": b64.encode(&bytes),
        "signatures": [{"key_id": key_id(&raw), "sig": b64.encode(pair.sign(&bytes).as_ref())}],
    }))
    .unwrap();
    Files(HashMap::from([(ring_url(RING), body)]))
}

#[test]
fn the_hold_flag_holds_the_timers_update_with_its_reason() {
    let home = tempfile::tempdir().unwrap();
    let pair = key_pair();
    assert_eq!(hold(home.path(), RING, NOW), None, "no ring applied holds nothing");
    run(home.path(), &ring_with(&pair, 3, json!({HOLD_FLAG: "bad build 1.2.3"})), &trust(&pair));
    let why = hold(home.path(), RING, NOW).unwrap();
    assert!(why.contains("seq 3") && why.contains("bad build 1.2.3"), "{why}");
    run(home.path(), &ring_with(&pair, 4, json!({HOLD_FLAG: true})), &trust(&pair));
    assert!(hold(home.path(), RING, NOW).unwrap().contains(HOLD_FLAG));
    // Expired: a hold nobody renews lets the host update again.
    assert_eq!(hold(home.path(), RING, NOW + 86_400), None);
    // Lifted by a newer signed file.
    run(home.path(), &ring_with(&pair, 5, json!({HOLD_FLAG: false})), &trust(&pair));
    assert_eq!(hold(home.path(), RING, NOW), None);
}

#[test]
fn an_empty_or_other_hold_value_holds_nothing() {
    let home = tempfile::tempdir().unwrap();
    let pair = key_pair();
    for (seq, value) in [(1, json!("  ")), (2, json!(1)), (3, json!(false))] {
        run(home.path(), &ring_with(&pair, seq, json!({HOLD_FLAG: value})), &trust(&pair));
        assert_eq!(hold(home.path(), RING, NOW), None, "{value}");
    }
    // A forged hold never lands.
    run(home.path(), &ring_with(&key_pair(), 9, json!({HOLD_FLAG: true})), &trust(&pair));
    assert_eq!(hold(home.path(), RING, NOW), None);
}
