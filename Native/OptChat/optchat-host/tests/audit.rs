//! Regressions from audit round 1: each test failed before its fix.

mod common;

use std::os::unix::fs::PermissionsExt;

use common::*;
use optchat_host::*;

#[test]
fn a_zoom_whose_end_overflows_is_refused_and_leaves_the_chat_usable() {
    let dir = tempfile::tempdir().unwrap();
    let chat = open(dir.path(), 128_000, instant(200));
    chat.append(Kind::User, "only message").unwrap();
    assert_eq!(
        chat.zoom(u64::MAX, 1).unwrap_err().to_string(),
        format!("No line {}+1.", u64::MAX)
    );
    // Nothing panicked under the state lock, so the chat still works.
    assert_eq!(chat.status().messages, 1);
    assert_eq!(chat.append(Kind::User, "more").unwrap(), 1);
}

#[test]
fn the_memory_and_its_export_are_private_to_the_user() {
    let dir = tempfile::tempdir().unwrap();
    let chat_dir = dir.path().join("chat");
    let chat = open(&chat_dir, 128_000, instant(200));
    chat.append(Kind::User, "a secret").unwrap();
    assert!(chat.wait_idle(None, WAIT));
    let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&chat_dir), 0o700);
    for f in std::fs::read_dir(&chat_dir).unwrap() {
        let path = f.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if name.starts_with(DB_FILE) {
            assert_eq!(mode(&path), 0o600, "{name}");
        }
    }
    let reader = optchat_host::db::ReadOnly::open(&chat_dir.join(DB_FILE)).unwrap();
    let export = dir.path().join("export");
    reader.export_text(&export).unwrap();
    for stream in ["main", "tree"] {
        let d = export.join(stream);
        assert_eq!(mode(&d), 0o700, "{stream}/");
        for f in std::fs::read_dir(&d).unwrap() {
            assert_eq!(mode(&f.unwrap().path()), 0o600, "{stream} file");
        }
    }
}

#[test]
fn a_declined_node_is_built_by_the_fallback_model() {
    // A refusal repeats on every try; retrying the same call would block
    // rule 3, and every later turn, forever.
    let dir = tempfile::tempdir().unwrap();
    let declined = std::sync::Arc::new(Fake(|_: &CompactRequest, _: &[Followup]| {
        Err(ModelError::refusal("refused: cyber"))
    }));
    let chat = OptChat::open_with_fallback(
        dir.path(),
        config(128_000).0,
        declined,
        Some(instant(200)),
        std::sync::Arc::new(SystemClock),
    )
    .unwrap();
    chat.append(Kind::User, &long(0)).unwrap();
    assert!(chat.settle(None, WAIT));
    assert!(chat.status().failures.is_empty());
    assert!(chat.render_view().text.contains("sum 0+1: "));
}
