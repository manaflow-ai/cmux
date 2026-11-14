use super::tag_targets;
use serde_json::json;

#[test]
fn tag_targets_skip_closed_sessions_other_tags_and_the_sender() {
    let sessions = vec![
        json!({"sessionId": "a", "name": "ao-cli-ls", "status": "running", "tags": {"area": {"value": "acpmux"}}}),
        json!({"sessionId": "b", "name": "ao-old", "status": "closed", "tags": {"area": {"value": "acpmux"}}}),
        json!({"sessionId": "c", "name": "cloud-x", "status": "idle", "tags": {"area": {"value": "cloud"}}}),
        json!({"sessionId": "d", "qualifiedSessionId": "huge-blue/d", "name": "huge-blue/ao-peer", "peer": "huge-blue", "status": "idle", "tags": {"area": "acpmux"}}),
        json!({"sessionId": "e", "name": "huge-blue/no-receipt", "peer": "huge-blue", "status": "idle", "tags": {"area": "acpmux"}}),
        json!({"sessionId": "me", "name": "ao-cli-audit", "status": "running", "tags": {"area": {"value": "acpmux"}}}),
    ];
    // A peer's session with the sender's bare id is another session: it still gets the message.
    let mut twin = sessions.clone();
    twin.push(
        json!({"sessionId": "me", "qualifiedSessionId": "huge-blue/me", "name": "huge-blue/twin",
                         "peer": "huge-blue", "status": "idle", "tags": {"area": "acpmux"}}),
    );
    let got = tag_targets(&twin, "area=acpmux", Some("me"));
    assert!(got.contains(&("huge-blue/me".to_owned(), "huge-blue/twin".to_owned())), "{got:?}");
    assert!(!got.iter().any(|(target, _)| target == "me"), "{got:?}");
    let got = tag_targets(&sessions, "area=acpmux", Some("me"));
    assert_eq!(
        got,
        vec![
            ("a".to_owned(), "ao-cli-ls".to_owned()),
            ("huge-blue/d".to_owned(), "huge-blue/ao-peer".to_owned())
        ]
    );
    // A peer's session goes by its peer/id; one without that key is skipped, never sent by its
    // bare id (which may name nothing here, or another session).
    assert_eq!(tag_targets(&sessions, "area", None).len(), 4);
}
