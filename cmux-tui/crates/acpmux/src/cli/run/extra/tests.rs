use super::{not_resumed_line, peer_add_params, resume_moves_off};
use serde_json::json;

#[test]
fn resume_moves_a_stopped_chat_off_a_machine_a_person_works_at_and_nothing_else() {
    for status in ["closed", "idle", "disconnected"] {
        let info = json!({"status": status, "peer": null, "turn": null, "movedTo": null});
        assert!(resume_moves_off(&info, true), "{status}");
        assert!(!resume_moves_off(&info, false), "{status}: a fleet host resumes in place");
    }
    // A live agent, a turn, a peer's chat, one moving or moved away: resumed where it is.
    for info in [
        json!({"status": "ready"}),
        json!({"status": "running"}),
        json!({"status": "waiting"}),
        json!({"status": "idle", "turn": {"turnId": "t"}}),
        json!({"status": "closed", "peer": "gcp-1"}),
        json!({"status": "closed", "moving": true}),
        json!({"status": "closed", "movedTo": {"host": "gcp-1", "sessionId": "m"}}),
    ] {
        assert!(!resume_moves_off(&info, true), "{info}");
    }
}

#[test]
fn host_add_saves_without_waiting_for_the_first_probe() {
    let params = peer_add_params("blackhole", "ssh://192.0.2.10", None);
    assert_eq!(params["wait"], false);
    assert_eq!(params["name"], "blackhole");
    assert_eq!(params["url"], "ssh://192.0.2.10");
}

#[test]
fn host_add_keeps_a_supplied_peer_token() {
    let params = peer_add_params("peer", "wss://peer.example", Some("secret"));
    assert_eq!(params["token"], "secret");
    assert_eq!(params["wait"], false);
}

/// A queue a daemon start holds for a person is named, with how to release it, instead of
/// "nothing is held" (a lane VM's queues sat a day behind that line).
#[test]
fn resume_names_a_hold_for_a_person_and_how_to_release_it() {
    let held = json!({"personHold": {"folder": "/Users/p/Downloads/x", "reason": "/Users/p/Downloads/x is in a privacy-protected folder; an agent starts there only when a person picks it"}});
    let line = not_resumed_line(&held, "lane-a");
    assert!(
        line.starts_with(
            "held for a person: /Users/p/Downloads/x is in a privacy-protected folder"
        ),
        "{line}"
    );
    assert!(line.contains("`acpmux session resume lane-a --open`"), "{line}");
    assert_eq!(not_resumed_line(&json!({"queue": []}), "lane-a"), "nothing is held");
    assert_eq!(not_resumed_line(&json!({"personHold": null}), "lane-a"), "nothing is held");
}
