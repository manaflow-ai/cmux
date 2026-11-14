use super::*;

#[test]
fn workflow_spool_retains_more_than_the_normal_two_segments() {
    let dir = cmux_unix_socket::short_test_dir("bg-workflow-spool");
    let mut spool = Spool::create_with_retention(dir.path(), "t", SEGMENT, true).unwrap();
    let data: Vec<u8> = (0..(2 * SEGMENT + 123) as usize).map(|i| (i % 251) as u8).collect();
    for chunk in data.chunks(64 << 10) {
        spool.write(chunk).unwrap();
    }
    drop(spool);
    assert_eq!(segments(dir.path(), "t").unwrap(), [0]);
    let complete = read_output(dir.path(), "t", Some(0), u64::MAX).unwrap();
    assert_eq!(complete.kept_from, 0);
    assert_eq!(complete.total, data.len() as u64);
    assert_eq!(complete.data, data);
}

#[test]
fn legacy_bg_specs_keep_bounded_retention() {
    let spec: Spec = serde_json::from_value(serde_json::json!({
        "dir":"/tmp", "id":"task", "sessionId":"owner", "command":"true",
        "cwd":"/tmp", "segment":10
    }))
    .unwrap();
    assert!(!spec.retain_all);
}

/// A summary line names the task by its description (else its command) on one line, says
/// how it ended, and its status is `ok` only for exit 0.
#[test]
fn a_tasks_outcome_is_one_line_and_a_status() {
    use serde_json::json;
    let view = |v: serde_json::Value| outcome(&v);
    let ran = view(json!({"state": "running", "command": "make\n  test", "description": " "}));
    assert_eq!(ran, ("Background command running: make test".to_owned(), "running"));
    let ok =
        view(json!({"state": "exited", "exitCode": 0, "command": "x", "description": "build"}));
    assert_eq!(ok, ("Background command finished: build (exit 0)".to_owned(), "ok"));
    let bad = view(json!({"state": "exited", "exitCode": 2, "command": "x"}));
    assert_eq!(bad, ("Background command finished: x (exit 2)".to_owned(), "failed"));
    let killed = view(json!({"state": "killed", "signal": 9, "command": "x"}));
    assert_eq!(killed, ("Background command killed: x (signal 9)".to_owned(), "failed"));
    assert_eq!(view(json!({"state": "stopped", "command": "x"})).1, "failed");
    assert_eq!(view(json!({"state": "lost", "command": "x"})).1, "failed");
    let long = label(None, &"a".repeat(500));
    assert_eq!(long.chars().count(), LABEL_MAX);
    assert!(long.ends_with('…'));
}

/// Rotation keeps the newest two segments, named by their start, and a read by whole-output
/// offset crosses them; one before the oldest kept byte starts at it.
#[test]
fn the_spool_keeps_two_segments_and_reads_across_them() {
    let dir = cmux_unix_socket::short_test_dir("bg-spool");
    let mut spool = Spool::create(dir.path(), "t", 10).unwrap();
    let data: Vec<u8> = (0..35u8).map(|i| b'a' + i % 26).collect();
    for chunk in data.chunks(4) {
        spool.write(chunk).unwrap();
    }
    assert_eq!(segments(dir.path(), "t").unwrap(), [20, 30]);
    let tail = read_output(dir.path(), "t", None, 8).unwrap();
    assert_eq!((tail.start, tail.total, tail.kept_from), (27, 35, 20));
    assert_eq!(tail.data, data[27..]);
    let across = read_output(dir.path(), "t", Some(0), 12).unwrap();
    assert_eq!((across.start, across.data.as_slice()), (20, &data[20..32]));
}

/// A segment that is listed but gone at every open (here a dangling link, as a rotation
/// between the listing and the open leaves it) is an error, not an empty output; a spool
/// with no segment at all is empty.
#[cfg(unix)]
#[test]
fn a_read_that_loses_every_race_with_rotation_is_an_error() {
    let dir = cmux_unix_socket::short_test_dir("bg-spool-race");
    let none = read_output(dir.path(), "t", None, 8).unwrap();
    assert_eq!((none.data.len(), none.total), (0, 0));
    let mut spool = Spool::create(dir.path(), "t", 10).unwrap();
    spool.write(b"0123456789abc").unwrap();
    let gone = segment_path(dir.path(), "t", 0);
    std::fs::remove_file(&gone).unwrap();
    std::os::unix::fs::symlink(dir.path().join("nowhere"), &gone).unwrap();
    let err = read_output(dir.path(), "t", None, 8).unwrap_err();
    assert_eq!(err.kind(), std::io::ErrorKind::Interrupted, "{err}");
}
