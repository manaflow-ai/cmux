use super::*;

#[test]
fn text_names_the_condition_the_owed_wakes_and_their_outbox_state() {
    let added = json!({"id": "w1", "to": "coord", "sessions": ["a", "b/c"],
        "until": ["ready", "permission"], "match": "BLOCKER", "active": true});
    assert_eq!(
        text(method::MUX_WATCH_ADD, &added),
        "Watch w1: wakes coord once when a or b/c is ready or permission, matching \"BLOCKER\".\n\
             List with acpmux watch ls; remove with acpmux watch rm w1."
    );
    let listed = json!({"watches": [{"id": "w1", "to": "coord", "sessions": ["a"],
        "until": ["ready"], "active": false, "offline": ["b"]}],
        "deliveries": [{"deliveryId": "d1", "target": "coord", "status": "failed",
        "attempts": 2, "error": "peer down"}]});
    assert_eq!(
        text(method::MUX_WATCH_LS, &listed),
        "w1  wakes coord when a is ready  (resolved, wake pending)  (offline: b)\n\
             Wakes owed:\n  d1 to coord: failed (attempt 2): peer down"
    );
    assert_eq!(
        text(method::MUX_WATCH_LS, &json!({"watches": [], "deliveries": []})),
        "No watches."
    );
    assert_eq!(
        text(method::MUX_WATCH_RM, &json!({"removed": "w1", "owed": 1})),
        "Removed watch w1. It still owes 1 wake(s) from before; they are delivered."
    );
}

#[test]
fn add_params_leave_defaults_to_the_daemon() {
    assert_eq!(
        add_params(vec!["a".into()], None, vec![], None),
        json!({"sessions": ["a"], "once": true})
    );
    assert_eq!(
        add_params(vec!["a".into()], Some("c".into()), vec!["done".into()], Some("x".into())),
        json!({"sessions": ["a"], "once": true, "to": "c", "until": ["done"], "match": "x"})
    );
}

#[test]
fn time_params_turn_at_every_and_until_into_epoch_ms() {
    let now = 1_700_000_000_000;
    assert_eq!(when_ms("+30m", now), Ok(now + 1_800_000));
    assert_eq!(when_ms("1h30m", now), Ok(now + 5_400_000), "the + may be left out");
    assert_eq!(when_ms("2023-11-14T22:13:20Z", now), Ok(1_700_000_000_000));
    assert!(when_ms("tomorrow", now).unwrap_err().contains("RFC 3339"));
    assert_eq!(
        time_params(Some("c".into()), None, Some("1h"), Some("+1d"), Some("check CI".into()), now),
        Ok(
            json!({"to": "c", "everyMs": 3_600_000, "endMs": now + 86_400_000, "prompt": "check CI"})
        )
    );
    assert_eq!(
        time_params(None, Some("+10s"), None, None, Some("hi".into()), now),
        Ok(json!({"atMs": now + 10_000, "prompt": "hi"}))
    );
    assert!(time_params(None, Some("+10s"), None, None, None, now).is_err(), "no prompt");
    assert!(time_params(None, Some("+10s"), None, Some("+1h"), Some("x".into()), now).is_err());
}

#[test]
fn time_watch_text_shows_the_next_due_time() {
    let added = json!({"id": "w2", "to": "coord", "sessions": [], "until": [], "active": true,
        "nextDueMs": 1_700_000_000_000u64, "everyMs": 5_400_000, "endMs": null, "prompt": "check CI"});
    assert_eq!(
        text(method::MUX_WATCH_ADD, &added),
        "Watch w2: wakes coord next at 2023-11-14T22:13:20Z, every 1h30m: \"check CI\".\n\
             List with acpmux watch ls; remove with acpmux watch rm w2."
    );
    let listed = json!({"watches": [{"id": "w3", "to": "coord", "sessions": [], "until": [],
        "active": false, "nextDueMs": null, "prompt": "once"}], "deliveries": []});
    assert_eq!(
        text(method::MUX_WATCH_LS, &listed),
        "w3  wakes coord fired: \"once\"  (resolved, wake pending)"
    );
}
