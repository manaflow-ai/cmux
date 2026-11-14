use super::*;

fn with(author: Value) -> Value {
    json!({"_meta": {"acpmux": {"author": author}}})
}

#[test]
fn an_author_is_read_checked_and_stamped() {
    assert_eq!(author(&json!({})).unwrap(), None);
    assert_eq!(author(&with(Value::Null)).unwrap(), None);
    let ana = author(&with(json!({"id": "tailnet:ana@example.com", "name": "Ana",
            "login": "ana@example.com", "node": "ana-mbp", "role": "dropped"})))
    .unwrap()
    .unwrap();
    assert_eq!(
        ana.provenance(),
        json!({"kind": "person_message", "from": "tailnet:ana@example.com", "fromName": "Ana",
                   "login": "ana@example.com", "node": "ana-mbp"})
    );
    let bo = author(&with(json!({"id": "user_42", "name": "Bo"}))).unwrap().unwrap();
    assert_eq!(
        bo.provenance(),
        json!({"kind": "person_message", "from": "user_42", "fromName": "Bo"})
    );
    assert_eq!(of_provenance(Some(&bo.provenance())), Some("user_42"));
    assert!(!bo.awaits_owner);
    let guest = author(&with(json!({"id": "guest:k3x9", "name": "Cy", "approval": "owner"})))
        .unwrap()
        .unwrap();
    assert!(guest.awaits_owner, "a link guest's prompt waits for the owner");
    let theirs = guest.provenance();
    assert_eq!(
        theirs,
        json!({"kind": "person_message", "from": "guest:k3x9", "fromName": "Cy",
                   "approval": "owner"})
    );
    assert!(awaits_owner(Some(&theirs)) && !awaits_owner(Some(&bo.provenance())));
    let null = author(&with(json!({"id": "user_42", "name": "Bo", "approval": null})));
    assert!(!null.unwrap().unwrap().awaits_owner);
    // A link guest as `cmux-tui-core` binds one (`guest:<share_id>.<guest_id>`, base64url),
    // and one whose sender left `approval` off: both wait for the owner.
    for raw in [
        json!({"id": "guest:Ab-_9xYz012345678901.q-_Z0aB1cD2", "name": "Theo",
                   "approval": "owner"}),
        json!({"id": "guest:Ab-_9xYz012345678901.q-_Z0aB1cD2", "name": "Theo"}),
        json!({"id": "guest:Ab-_9xYz012345678901.q-_Z0aB1cD2", "name": "Theo",
                   "approval": null}),
    ] {
        let guest = author(&with(raw.clone())).unwrap().unwrap();
        assert!(guest.awaits_owner, "a link guest's prompt ran unapproved: {raw}");
        assert_eq!(guest.provenance()["approval"], APPROVAL_OWNER, "{raw}");
    }
    // A guest's record that names no approval (an older writer) still waits on restore.
    let unmarked = json!({"kind": "person_message", "from": "guest:k3x9", "fromName": "Cy"});
    assert!(awaits_owner(Some(&unmarked)));
    assert!(!awaits_owner(Some(&json!({"kind": "agent_message", "from": "guest:k3x9"}))));
    assert_eq!(of_provenance(Some(&json!({"kind": "agent_message", "from": "acp:x"}))), None);
    assert_eq!(of_provenance(None), None);
    let named = |p: Value| listed(Some(&p)).map(|a| (a.id, a.name));
    assert_eq!(named(bo.provenance()), Some(("user_42".into(), "Bo".into())));
    assert_eq!(
        named(json!({"kind": "person_message", "from": "user_7"})),
        Some(("user_7".into(), "user_7".into())),
        "a record with no name lists the id"
    );
    assert_eq!(named(json!({"kind": "agent_message", "from": "acp:x", "fromName": "b"})), None);
    assert!(listed(None).is_none());
    for bad in [
        json!("tailnet:ana"),
        json!({"name": "Ana"}),
        json!({"id": "tailnet:ana"}),
        json!({"id": "ana", "name": "Ana"}),
        json!({"id": "tailnet:", "name": "Ana"}),
        json!({"id": "tailnet:a b", "name": "Ana"}),
        json!({"id": format!("user_{}", "x".repeat(MAX_FIELD_BYTES)), "name": "Ana"}),
        json!({"id": "user_1", "name": "n".repeat(MAX_NAME_CHARS + 1)}),
        json!({"id": "user_1", "name": "Ana\u{202E}nimda"}),
        json!({"id": "user_1", "name": "Ana", "node": "a\nb"}),
        json!({"id": "user_1", "name": " "}),
        json!({"id": "user_1", "name": "Ana", "login": 7}),
        json!({"id": "guest:", "name": "Cy"}),
        json!({"id": "guest:a b", "name": "Cy"}),
        json!({"id": "user_1", "name": "Ana", "approval": "anyone"}),
        json!({"id": "user_1", "name": "Ana", "approval": true}),
        json!({"id": "user_1", "name": "Ana", "avatar": "http://example.com/a.png"}),
        json!({"id": "user_1", "name": "Ana", "avatar": "https://"}),
        json!({"id": "user_1", "name": "Ana", "avatar": "https://x/a b.png"}),
        json!({"id": "user_1", "name": "Ana", "avatar": "https://x/\u{200B}.png"}),
        json!({"id": "user_1", "name": "Ana",
                   "avatar": format!("https://x/{}", "a".repeat(MAX_AVATAR_BYTES))}),
    ] {
        let e = author(&with(bad.clone())).expect_err(&bad.to_string());
        assert_eq!(e.data.unwrap()["reason"], "author.value_refused", "{bad}");
    }
}

/// A signed-in guest's picture rides its author into the provenance (`fromAvatar`) and the
/// queue listing (`avatar`); the agent reads who sent a person's prompt, never the owner's.
#[test]
fn a_persons_avatar_reaches_the_provenance_and_the_agent_reads_their_name() {
    let url = "https://lh3.example.com/a/photo.png?sz=96";
    let guest = author(&with(json!({"id": "guest:s1.g1", "name": "Cy", "approval": "owner",
            "role": "talk", "avatar": url})))
    .unwrap()
    .unwrap();
    assert_eq!(guest.avatar.as_deref(), Some(url));
    let theirs = guest.provenance();
    assert_eq!(
        theirs,
        json!({"kind": "person_message", "from": "guest:s1.g1", "fromName": "Cy",
                   "fromAvatar": url, "approval": "owner"})
    );
    assert!(awaits_owner(Some(&theirs)), "a guest's prompt with a picture is still held");
    let shown = listed(Some(&theirs)).unwrap();
    assert_eq!((shown.name.as_str(), shown.avatar.as_deref()), ("Cy", Some(url)));
    let json = serde_json::to_value(&shown).unwrap();
    assert_eq!(json, json!({"id": "guest:s1.g1", "name": "Cy", "avatar": url}));
    // None: the field is left out, as an older daemon's listing has none.
    let plain = listed(Some(&json!({"kind": "person_message", "from": "user_1"}))).unwrap();
    assert_eq!(serde_json::to_value(&plain).unwrap(), json!({"id": "user_1", "name": "user_1"}));
    // A record with a bad picture lists none rather than passing it on.
    let bad = json!({"kind": "person_message", "from": "user_1", "fromAvatar": "javascript:x"});
    assert_eq!(listed(Some(&bad)).unwrap().avatar, None);
    assert_eq!(
        agent_label(Some(&theirs)),
        Some(json!({"type": "text",
                "text": "[Message from Cy, a guest in this shared chat]"}))
    );
    let bo = json!({"kind": "person_message", "from": "tailnet:bo@example.com", "fromName": "Bo"});
    assert_eq!(
        agent_label(Some(&bo)).unwrap()["text"],
        "[Message from Bo, a participant in this shared chat]"
    );
    assert_eq!(agent_label(None), None, "the owner's own prompt");
    assert_eq!(agent_label(Some(&json!({"kind": "agent_message", "from": "acp:x"}))), None);
}

#[test]
fn only_the_sender_may_change_a_prompt() {
    let not_author = |r: Result<(), RpcError>| r.unwrap_err().data.unwrap()["reason"].clone();
    assert!(may_change(None, Some("user_1")).is_ok(), "the hub's own change");
    assert!(may_change(Some(Some("user_1")), Some("user_1")).is_ok());
    assert!(may_change(Some(None), None).is_ok(), "the owner, the owner's");
    assert_eq!(not_author(may_change(Some(None), Some("user_1"))), "queue.not_author");
    assert_eq!(not_author(may_change(Some(Some("user_2")), Some("user_1"))), "queue.not_author");
    assert_eq!(not_author(may_change(Some(Some("user_1")), None)), "queue.not_author");
}

#[test]
fn a_restored_persons_prompt_takes_no_supersede_key() {
    let person = json!({"kind": PERSON_MESSAGE, "from": "user_1", "fromName": "Ana"});
    let keyed = json!({"supersede": "status", "_meta": {"provenance": person}});
    assert_eq!(restored_supersede(&keyed), None);
    let agent = json!({"supersede": "status", "_meta": {"provenance": {"kind": "agent_message"}}});
    assert_eq!(restored_supersede(&agent), Some("status"));
    assert_eq!(restored_supersede(&json!({"supersede": "status"})), Some("status"));
    assert_eq!(restored_supersede(&json!({})), None);
}

#[test]
fn a_persons_answer_adds_id_and_name_beside_a_devices() {
    let ana = Author {
        id: "user_1".into(),
        name: "Ana".into(),
        login: None,
        node: None,
        avatar: None,
        awaits_owner: false,
    };
    let device = json!({"device": "phone-1", "feedItem": "f-1"});
    assert_eq!(answered_by(None, None), None);
    assert_eq!(answered_by(Some(device.clone()), None), Some(device.clone()));
    assert_eq!(answered_by(None, Some(&ana)), Some(json!({"id": "user_1", "name": "Ana"})));
    assert_eq!(
        answered_by(Some(device), Some(&ana)),
        Some(json!({"device": "phone-1", "feedItem": "f-1", "id": "user_1", "name": "Ana"}))
    );
}
