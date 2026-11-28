use super::sent_line;
use serde_json::json;

/// Leo: "the send/recieve messages are still only the older names". The confirmation names
/// the target by its given name, its HOST/NAME beside it; a target without one reads as before.
#[test]
fn a_send_confirmation_names_the_target_by_its_given_name() {
    let row = |accepted| {
        json!({"ok": true, "to": "studio-mac/coord-old", "promptId": "p1",
               "deliveryId": "d1", "delivery": "started", "accepted": accepted})
    };
    assert_eq!(
        sent_line(&row(json!({"sessionId": "s1", "displayName": "Mango"}))),
        "Sent to Mango · studio-mac/coord-old: it started a turn with it (promptId p1)."
    );
    assert_eq!(
        sent_line(&row(json!({"sessionId": "s1"}))),
        "Sent to studio-mac/coord-old: it started a turn with it (promptId p1)."
    );
    // Sent by the given name: said once.
    let mut by_given = row(json!({"sessionId": "s1", "displayName": "Mango"}));
    by_given["to"] = json!("Mango");
    assert_eq!(sent_line(&by_given), "Sent to Mango: it started a turn with it (promptId p1).");
}
