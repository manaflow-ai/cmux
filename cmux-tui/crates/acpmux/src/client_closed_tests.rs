//! Why a daemon connection closed, as codes (`closed_cause`, `recent_panic`).

use super::*;

const NOW: u64 = 1_800_000_000_000;

fn log(lines: &[Value]) -> tempfile::NamedTempFile {
    let file = tempfile::NamedTempFile::new().unwrap();
    let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
    std::fs::write(file.path(), text).unwrap();
    file
}

const PID: i32 = 4242;

fn panic_line(at_ms: u64, test: bool) -> Value {
    json!({"process": "acpmux", "pid": PID, "message": "secret-looking value sk-xxx in the panic text", "location": "src/hub/relay.rs:42:9",
        "thread": "tokio-runtime-worker", "at_ms": at_ms, "test": test, "backtrace": "frames"})
}

#[test]
fn a_recent_panic_is_named_by_its_thread_and_place_only() {
    let file = log(&[panic_line(NOW - 3_600_000, false), panic_line(NOW - 5_000, false)]);
    let panic = recent_panic(file.path(), NOW, Some(PID)).expect("a panic 5 s ago");
    assert_eq!(
        panic,
        json!({"thread": "tokio-runtime-worker", "location": "src/hub/relay.rs:42:9", "at_ms": NOW - 5_000})
    );
    // The message and the backtrace never leave the log.
    assert!(!panic.to_string().contains("sk-xxx") && !panic.to_string().contains("frames"));
}

#[test]
fn an_old_test_or_broken_panic_line_explains_nothing() {
    let old = log(&[panic_line(NOW - PANIC_WINDOW_MS - 1, false)]);
    assert_eq!(recent_panic(old.path(), NOW, Some(PID)), None);
    let test = log(&[panic_line(NOW - 1_000, true)]);
    assert_eq!(recent_panic(test.path(), NOW, Some(PID)), None);
    let broken = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(broken.path(), "{not json\n").unwrap();
    assert_eq!(recent_panic(broken.path(), NOW, Some(PID)), None);
    assert_eq!(
        recent_panic(std::path::Path::new("/nonexistent/acpmux/panics.jsonl"), NOW, Some(PID)),
        None
    );
}

#[test]
fn each_way_a_daemon_goes_has_its_own_cause() {
    let panic = json!({"thread": "relay", "location": "src/a.rs:1:1", "at_ms": NOW});
    assert_eq!(closed_cause(Some(7), true, true, Some(&panic)).0, "panicked");
    assert!(
        closed_cause(Some(7), true, true, Some(&panic)).1.contains("thread relay at src/a.rs:1:1")
    );
    assert_eq!(closed_cause(Some(7), true, true, None).0, "dropped");
    assert_eq!(closed_cause(Some(7), false, true, None).0, "crashed");
    // The prod proof's case (cmuxterm-hq run 42112686310): no pid file, the socket left behind.
    assert_eq!(closed_cause(None, false, true, None).0, "socket_left");
    assert_eq!(closed_cause(None, false, false, None).0, "shut_down");
}

#[test]
fn the_cli_error_carries_the_cause_as_data() {
    let closed: anyhow::Error = TransportClosed {
        message: "daemon connection closed while waiting for the reply to session/new".into(),
        cause: "panicked",
        panic: Some(json!({"thread": "relay", "location": "src/a.rs:1:1", "at_ms": NOW})),
    }
    .into();
    let envelope = crate::cli::errors::classify(&closed).envelope();
    assert_eq!(envelope["error"]["detail"], "daemon_closed");
    assert_eq!(envelope["error"]["retryable"], true);
    assert_eq!(envelope["error"]["data"]["cause"], "panicked");
    assert_eq!(envelope["error"]["data"]["panic"]["location"], "src/a.rs:1:1");
}

#[test]
fn only_this_daemons_panic_explains_its_drop() {
    // A panic an earlier daemon logged minutes ago: a restarted daemon's drop is not `panicked`.
    let file = log(&[panic_line(NOW - 5_000, false)]);
    assert_eq!(recent_panic(file.path(), NOW, Some(PID + 1)), None);
    // No pid file: no daemon to match, so no panic is claimed.
    assert_eq!(recent_panic(file.path(), NOW, None), None);
    assert!(recent_panic(file.path(), NOW, Some(PID)).is_some());
}

#[cfg(unix)]
#[test]
fn the_panic_log_is_read_as_a_state_file() {
    let dir = tempfile::tempdir().unwrap();
    let real = dir.path().join("real.jsonl");
    std::fs::write(&real, format!("{}\n", panic_line(NOW - 1_000, false))).unwrap();
    // A symlink put in its place is never followed.
    let link = dir.path().join("panics.jsonl");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    assert_eq!(recent_panic(&link, NOW, Some(PID)), None);
    // A FIFO is never waited on.
    let fifo = dir.path().join("fifo.jsonl");
    let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    // SAFETY: mkfifo on a NUL-terminated path in a private temp directory.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    assert_eq!(recent_panic(&fifo, NOW, Some(PID)), None);
}
