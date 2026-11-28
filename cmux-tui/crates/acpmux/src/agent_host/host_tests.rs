/// A pooled host ends at the end of its wait only when no controller
/// ever said `Hello`; a session's host never ends this way.
#[test]
fn only_a_pooled_host_with_no_controller_yet_ends_after_its_wait() {
    assert!(super::pooled_without_owner(true, None));
    assert!(!super::pooled_without_owner(true, Some(1)));
    assert!(!super::pooled_without_owner(false, None));
}

/// The leader is waited for without being reaped: while it is a zombie
/// its process group id cannot be reused, so ending the group then can
/// never signal another process group.
#[test]
fn waiting_for_the_leader_leaves_it_unreaped() {
    let mut child = std::process::Command::new("/bin/sh").args(["-c", "exit 3"]).spawn().unwrap();
    let pid = child.id() as i32;
    assert!(super::wait_exit_unreaped(pid), "the wait failed");
    // SAFETY: signal 0 to this test's own child only checks existence.
    assert_eq!(unsafe { libc::kill(pid, 0) }, 0, "the leader was reaped by the wait");
    assert_eq!(child.wait().unwrap().code(), Some(3), "the exit status is kept for the reaper");
}

/// An entry too big for one frame is kept as a frame that fits, never as an empty one:
/// an answer whose id alone is over the limit becomes a stderr note, which a next daemon
/// does not need.
#[test]
fn an_entry_whose_replacement_is_over_the_limit_too_is_kept_as_a_note() {
    use super::{Entry, encode_entry};
    let answer = Entry::In { msg: serde_json::json!({"id": "x".repeat(300), "result": {}}) };
    let (bytes, needed) = encode_entry(5, &answer, 200).expect("a note fits");
    assert!(!needed, "a stderr note keeps no orphaned host waiting");
    let body: serde_json::Value = serde_json::from_slice(&bytes[4..]).unwrap();
    assert_eq!(body["h"], 5);
    assert_eq!(body["e"]["line"], "[entry 5 over the frame limit dropped]", "{body}");

    let small = Entry::In { msg: serde_json::json!({"id": 1, "result": "y".repeat(300)}) };
    let (bytes, needed) = encode_entry(6, &small, 200).expect("the error answer fits");
    assert!(needed, "an answer is logged by a next daemon");
    let body: serde_json::Value = serde_json::from_slice(&bytes[4..]).unwrap();
    assert_eq!(body["e"]["msg"]["id"], 1, "{body}");
    assert!(body["e"]["msg"]["error"].is_object(), "{body}");

    assert!(encode_entry(7, &small, 20).is_none(), "nothing fits: no empty frame");
}

/// An entry too big for one frame is replaced, not dropped with its connection: an
/// answer by an error answer to the same id, anything else by a stderr note.
#[test]
fn an_entry_over_the_frame_limit_is_answered_or_noted() {
    use super::{Entry, TapDir, over_frame_limit};
    let answer = Entry::In { msg: serde_json::json!({"jsonrpc": "2.0", "id": 7, "result": {}}) };
    let Entry::In { msg } = over_frame_limit(3, &answer) else { panic!("not an answer") };
    assert_eq!(msg["id"], 7);
    assert_eq!(msg["error"]["message"], "agent answer was over the frame limit");
    assert!(msg.get("result").is_none());

    let update = serde_json::json!({"jsonrpc": "2.0", "method": "session/update", "params": {}});
    for entry in [
        Entry::In { msg: update },
        Entry::Tap { dir: TapDir::In, msg: serde_json::json!({"id": 1, "result": {}}) },
    ] {
        let Entry::Err { line } = over_frame_limit(4, &entry) else { panic!("not a note") };
        assert_eq!(line, "[entry 4 over the frame limit dropped]");
    }
}
