//! A store that keeps nothing on disk puts the leftover patch in the system's shared scratch
//! folder. There it is made new and owner-only, so a path someone else made first is never
//! written through (security review of cmux#52931, item 5).

use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;
use std::process::Command;
use std::sync::Arc;

use serde_json::json;

use crate::hub::{Hub, NewRequest};

fn memory_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap().trim().to_owned()
}

/// A checkout with one commit and a change after it. Answers the commit's tree.
fn checkout(dir: &Path) -> String {
    git(dir, &["init", "-q"]);
    git(dir, &["config", "user.email", "t@example.com"]);
    git(dir, &["config", "user.name", "t"]);
    std::fs::write(dir.join("a.txt"), "one\n").unwrap();
    git(dir, &["add", "a.txt"]);
    git(dir, &["commit", "-qm", "one"]);
    std::fs::write(dir.join("a.txt"), "two\n").unwrap();
    git(dir, &["rev-parse", "HEAD^{tree}"])
}

fn mode(path: &Path) -> u32 {
    std::fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
}

#[tokio::test]
async fn the_scratch_patch_is_made_new_and_owner_only() {
    let hub = memory_hub();
    let work = tempfile::tempdir().unwrap();
    let anchor = checkout(work.path());
    let request = NewRequest {
        harness: Some("fake".into()),
        cwd: Some(work.path().to_path_buf()),
        ..NewRequest::default()
    };
    let session = hub.new_session(request).await.unwrap();
    assert!(hub.session_dir(&session.id).is_none(), "this store keeps nothing on disk");
    let scratch = std::env::temp_dir();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        as u64;

    // A file made first, world-readable, under the name a write goes through on its way.
    let patch = scratch.join(format!("acpmux-{}-auto-leftover-{now}.patch", session.id));
    let beside = patch.with_extension(format!("tmp-{}", std::process::id()));
    std::fs::write(&beside, b"theirs").unwrap();
    std::fs::set_permissions(&beside, std::fs::Permissions::from_mode(0o644)).unwrap();
    let written = super::write(&hub, &session, &anchor, now).await;
    let kept = std::fs::read(&beside).ok();
    let made = written
        .as_ref()
        .ok()
        .and_then(Option::as_ref)
        .map(|leftover| mode(Path::new(&leftover.path)));
    let _ = std::fs::remove_file(&beside);
    let _ = std::fs::remove_file(&patch);
    assert_eq!(made, Some(0o600), "the patch is owner-only: {written:?}");
    assert_eq!(kept.as_deref(), Some(&b"theirs"[..]), "the file made first was not written");

    // A file made first under the patch's own name is refused, never replaced.
    let later = now + 1;
    let patch = scratch.join(format!("acpmux-{}-auto-leftover-{later}.patch", session.id));
    std::fs::write(&patch, b"theirs").unwrap();
    let written = super::write(&hub, &session, &anchor, later).await;
    let kept = std::fs::read(&patch).ok();
    let _ = std::fs::remove_file(&patch);
    assert!(written.is_err(), "a path made first is refused: {written:?}");
    assert_eq!(kept.as_deref(), Some(&b"theirs"[..]));
}
