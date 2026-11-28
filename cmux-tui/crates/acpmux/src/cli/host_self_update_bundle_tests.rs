//! The patch bundle tick on a fake file server and a fake probe: applied, already applied,
//! rolled back and never retried, a bad signature, another build, and nothing published.

use std::collections::HashMap;

use base64::Engine as _;
use futures::future::BoxFuture;
use ring::rand::SystemRandom;
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::json;
use sha2::{Digest as _, Sha256};

use super::*;
use cmux_signed_envelope::key_id;

const CHANNEL: &str = "feat-cmux-next";
const TARGET: &str = "x86_64-unknown-linux-musl";
const NOW: u64 = 1_795_400_000;
const BASE: &str = "41994452b7c0d1e2f3a4b5c6d7e8f90123456789";

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

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn published(pair: &Ed25519KeyPair, id: &str, content: &[u8]) -> Files {
    let b64 = base64::engine::general_purpose::STANDARD;
    let payload = json!({
        "schema": 1, "purpose": "cmux-patch-bundle", "id": id, "target": TARGET, "base": BASE,
        "issued_at": NOW - 60, "expires_at": NOW + 86_400,
        "files": [{"path": "web/app.js", "sha256": hex(&Sha256::digest(content)),
                   "content": b64.encode(content)}],
    });
    let bytes = serde_json::to_vec(&payload).unwrap();
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    let body = serde_json::to_vec(&json!({
        "schema": 1,
        "payload": b64.encode(&bytes),
        "signatures": [{"key_id": key_id(&raw), "sig": b64.encode(pair.sign(&bytes).as_ref())}],
    }))
    .unwrap();
    Files(HashMap::from([(bundle_url(CHANNEL, TARGET), body)]))
}

/// A fresh acpmux home this test made; removed when dropped.
struct Home(PathBuf);

impl Home {
    fn new(name: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("acpmux-bundle-tick-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Home(dir)
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn run(
    home: &Path,
    files: &Files,
    keys: &[Key],
    base: Option<&str>,
    probe: &mut dyn FnMut() -> Result<(), String>,
) -> BundleOutcome {
    futures::executor::block_on(tick(home, files, keys, CHANNEL, TARGET, base, NOW, probe))
}

#[test]
fn a_healthy_bundle_is_applied_once_onto_the_short_build_commit() {
    let pair = key_pair();
    let home = Home::new("ok");
    let files = published(&pair, "fix-1", b"new");
    let mut probes = 0;
    let outcome = run(&home.0, &files, &trust(&pair), Some(&BASE[..9]), &mut || {
        probes += 1;
        Ok(())
    });
    assert_eq!(outcome, BundleOutcome::Applied { id: "fix-1".into(), files: 1 });
    assert_eq!(probes, 1);
    assert_eq!(std::fs::read(root(&home.0, TARGET).join("web/app.js")).unwrap(), b"new");
    assert!(outcome.line().unwrap().contains("applied 1 file"));
    let again = run(&home.0, &files, &trust(&pair), Some(&BASE[..9]), &mut || panic!("no probe"));
    assert_eq!(again, BundleOutcome::AlreadyApplied { id: "fix-1".into() });
    assert_eq!(again.line(), None);
}

#[test]
fn a_failed_probe_rolls_back_and_the_id_is_not_tried_again() {
    let pair = key_pair();
    let home = Home::new("rollback");
    let files = published(&pair, "fix-bad", b"broken");
    let outcome = run(&home.0, &files, &trust(&pair), Some(BASE), &mut || {
        Err("the daemon does not answer (no pid)".into())
    });
    assert_eq!(
        outcome,
        BundleOutcome::RolledBack {
            id: "fix-bad".into(),
            why: "the daemon does not answer (no pid)".into()
        }
    );
    assert!(!root(&home.0, TARGET).join("web/app.js").exists());
    let again = run(&home.0, &files, &trust(&pair), Some(BASE), &mut || panic!("no probe"));
    assert_eq!(again, BundleOutcome::Bad { id: "fix-bad".into() });
}

#[test]
fn a_bad_signature_another_build_or_nothing_published_writes_nothing() {
    let pair = key_pair();
    let home = Home::new("refused");
    let files = published(&key_pair(), "fix-1", b"x");
    let outcome = run(&home.0, &files, &trust(&pair), Some(BASE), &mut || panic!("no probe"));
    assert!(matches!(outcome, BundleOutcome::Refused(ref why) if why.contains("signature")));
    let files = published(&pair, "fix-1", b"x");
    let other = run(&home.0, &files, &trust(&pair), Some("0123456789"), &mut || panic!("no probe"));
    assert!(matches!(other, BundleOutcome::Refused(ref why) if why.contains("applies onto")));
    let none =
        run(&home.0, &Files(HashMap::new()), &trust(&pair), Some(BASE), &mut || panic!("no probe"));
    assert!(matches!(none, BundleOutcome::NotRead(_)));
    assert_eq!(none.line(), None);
    let unknown = run(&home.0, &files, &trust(&pair), None, &mut || panic!("no probe"));
    assert!(matches!(unknown, BundleOutcome::NotRead(_)));
    assert!(!root(&home.0, TARGET).join("web/app.js").exists());
}

#[test]
fn status_gap_wants_a_live_pid() {
    assert_eq!(status_gap(r#"{"pid": 42, "build": "x"}"#), None);
    assert!(status_gap(r#"{"pid": null}"#).unwrap().contains("no pid"));
    assert!(status_gap("").unwrap().contains("not JSON"));
}

#[cfg(unix)]
#[test]
fn daemon_probe_reads_a_large_reply_and_times_out() {
    use std::os::unix::fs::PermissionsExt as _;
    let home = Home::new("probe");
    let fake = home.0.join("acpmux");
    // A reply bigger than a pipe holds, as the real status is.
    std::fs::write(
        &fake,
        "#!/bin/sh\nprintf '{\"pid\": 7, \"pad\": \"'; head -c 300000 /dev/zero | tr '\\0' a; printf '\"}'\n",
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let state = home.0.join("state");
    assert_eq!(daemon_probe(&fake, &state, std::time::Duration::from_secs(10)), Ok(()));
    std::fs::write(&fake, "#!/bin/sh\nsleep 5\n").unwrap();
    let started = std::time::Instant::now();
    let err = daemon_probe(&fake, &state, std::time::Duration::from_millis(200)).unwrap_err();
    assert!(err.contains("did not answer within"), "{err}");
    assert!(started.elapsed() < std::time::Duration::from_secs(3));
}
