use super::*;
use serde_json::json;

const BUILD: &str = "abc1234-20261122";

#[test]
fn a_successor_of_this_build_that_started_after_the_wait_serves_this_start() {
    // 21:38Z: 12396 took the lock at :43 on the new build; the swap's start waited from :31.
    let status = json!({"pid": 12396, "build": BUILD, "startedAt": 2_000});
    assert!(serves_this_start(&status, BUILD, 1_000));
    assert!(serves_this_start(&status, BUILD, 2_000));
}

#[test]
fn the_daemon_this_start_replaces_is_asked() {
    // The old build: the update this start exists for.
    let old = json!({"pid": 8581, "build": "fff0000-20261121", "startedAt": 2_000});
    assert!(!serves_this_start(&old, BUILD, 1_000));
    // The same build, started before this start waited (a daemon a heal or rollback restarts
    // from a backup bundle, or a detached start this one was asked to replace).
    let earlier = json!({"pid": 8581, "build": BUILD, "startedAt": 999});
    assert!(!serves_this_start(&earlier, BUILD, 1_000));
}

#[test]
fn unstamped_or_unreadable_holders_are_asked() {
    let unstamped = json!({"build": UNSTAMPED, "startedAt": 2_000});
    assert!(!serves_this_start(&unstamped, UNSTAMPED, 1_000));
    assert!(!serves_this_start(&json!({"build": BUILD}), BUILD, 1_000));
    assert!(!serves_this_start(&json!({"startedAt": 2_000}), BUILD, 1_000));
    assert!(!serves_this_start(&json!({"build": BUILD, "startedAt": "2000"}), BUILD, 1_000));
}

#[test]
fn the_ready_line_names_the_serving_daemon() {
    let status = json!({"pid": 7, "socket": "/s", "listen": "127.0.0.1:1", "webUrl": "http://x"});
    let ready = ready_line(&status);
    assert_eq!(ready["ready"], true);
    assert_eq!(ready["lockHeld"], true);
    assert_eq!(ready["pid"], 7);
    assert_eq!(ready["socket"], "/s");
}
