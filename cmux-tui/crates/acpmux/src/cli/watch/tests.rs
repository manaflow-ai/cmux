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
