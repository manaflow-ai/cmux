use super::*;
use crate::config::Config;
use crate::store::{MemoryStore, Store};
use std::sync::Arc;

fn row(id: &str, extra: Value) -> Value {
    let mut row = json!({"schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": "claude", "family": "claude", "agentSessionId": id,
        "cwd": "/nonexistent", "status": "closed", "createdAt": 1, "updatedAt": 1});
    row.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
    row
}

fn hub(rows: Vec<Value>) -> Arc<Hub> {
    let store = MemoryStore::default();
    for row in rows {
        store.save(&serde_json::from_value(row).unwrap()).unwrap();
    }
    Hub::new(Config::default(), Box::new(store))
}

#[tokio::test]
async fn closed_activity_keeps_preview_parent_and_newest_session_precedence() {
    let hub = hub(vec![
        row("root", json!({})),
        row("old", json!({"agentSessionId": "chat", "updatedAt": 2, "preview": "old"})),
        row(
            "new",
            json!({"agentSessionId": "chat", "updatedAt": 3,
            "preview": " new\n reply ", "unread": true, "lastTurn": {"status": "failed"},
            "tags": {"spawnedBy": {"value": "root"}},
            "configOptions": [{"payload": "x".repeat(32_768)}]}),
        ),
    ]);
    let activity = hub.chat_activity();
    let mut chat = json!({"key": "claude-code:chat"});
    activity.decorate(&mut chat);
    assert_eq!(
        chat,
        json!({"key": "claude-code:chat", "attention": null,
        "preview": "new reply", "parent": "claude-code:root"})
    );
    assert!(activity.has_parent("claude-code:chat"));
    let mut missing = json!({"key": "claude-code:missing", "attention": "unread"});
    activity.decorate(&mut missing);
    assert_eq!(missing["attention"], Value::Null);
}

#[tokio::test]
async fn activity_parent_keeps_lineage_precedence_expiry_and_one_level_visibility() {
    let lineage = json!({"parent": "root", "root": "root", "depth": 1});
    let cases = [
        (json!({"tags": {"spawnedBy": {"value": "root"}}}), json!({}), true),
        (json!({"lineage": lineage, "tags": {"spawnedBy": {"value": "missing"}}}), json!({}), true),
        (
            json!({"subsession": {"startedBy": "root", "shortName": "child", "depth": 1}}),
            json!({}),
            true,
        ),
        (json!({"tags": {"spawnedBy": {"value": "root", "expires_at": 1}}}), json!({}), false),
        (json!({"tags": {"spawnedBy": {"value": "child"}}}), json!({}), false),
        (json!({"tags": {"spawnedBy": {"value": "missing"}}}), json!({}), false),
        (json!({"lineage": lineage}), json!({"tags": {"archived": {"value": "1"}}}), false),
        (
            json!({"lineage": lineage}),
            json!({"tags": {"archived": {"value": "1", "expires_at": 1}}}),
            true,
        ),
        (
            json!({"lineage": lineage}),
            json!({"lineage": {"parent": "child", "root": "child", "depth": 1}}),
            false,
        ),
        (json!({"lineage": lineage}), json!({"tags": {"spawnedBy": {"value": "missing"}}}), false),
    ];
    for (index, (child, parent, listed)) in cases.into_iter().enumerate() {
        let hub = hub(vec![row("child", child.clone()), row("root", parent.clone())]);
        let session = hub.resolve("child").unwrap();
        let expected = listed.then(|| "root".to_owned());
        assert_eq!(
            hub.spawned_by_session(&session),
            expected,
            "case {index}, child={child}, parent={parent}"
        );
        assert_eq!(hub.spawned_by(&session.meta()), expected);
        assert_eq!(
            hub.chat_activity_fields(&session)["parent"],
            if listed { json!("claude-code:root") } else { Value::Null }
        );
    }
}
