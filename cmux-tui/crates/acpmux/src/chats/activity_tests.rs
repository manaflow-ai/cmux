use super::*;
use crate::config::Config;
use crate::store::{MemoryStore, Store};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

fn row(id: &str, extra: Value) -> Value {
    let mut row = json!({"schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": "claude", "family": "claude", "agentSessionId": id,
        "cwd": "/nonexistent", "status": "closed", "createdAt": 1, "updatedAt": 1});
    row.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
    row
}

fn decorated(hub: &Hub, key: &str) -> Value {
    let mut chat = json!({"key": key});
    hub.chat_activity().decorate(&mut chat);
    chat
}

fn make_hub(rows: Vec<Value>) -> Arc<Hub> {
    let store = MemoryStore::default();
    for row in rows {
        store.save(&serde_json::from_value(row).unwrap()).unwrap();
    }
    Hub::new(Config::default(), Box::new(store))
}

impl Hub {
    fn test_append_activity(&self, id: &str, kind: &str, msg: Value) {
        let session = self.resolve(id).unwrap();
        self.append(&session, "mux", kind, msg);
    }

    fn test_set_status(&self, id: &str, status: SessionStatus) {
        let session = self.resolve(id).unwrap();
        self.set_status(&session, status);
    }
}

#[tokio::test]
async fn closed_activity_keeps_preview_parent_and_newest_session_precedence() {
    let hub = make_hub(vec![
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
        let hub = make_hub(vec![row("child", child.clone()), row("root", parent.clone())]);
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

#[tokio::test]
async fn closed_winner_updates_through_composer_draft_and_rules() {
    let hub = make_hub(vec![
        row("a", json!({"agentSessionId": "chat", "updatedAt": 2, "preview": "A"})),
        row("b", json!({"agentSessionId": "chat", "updatedAt": 3, "preview": "B"})),
    ]);
    let key = "claude-code:chat";
    assert_eq!(decorated(&hub, key)["preview"], "B");
    let a = hub.resolve("a").unwrap();
    hub.set_composer_draft(&a, "draft").unwrap();
    assert_eq!(decorated(&hub, key)["preview"], "A");

    let hub2 = make_hub(vec![
        row("a", json!({"agentSessionId": "chat", "updatedAt": 2, "preview": "A"})),
        row("b", json!({"agentSessionId": "chat", "updatedAt": 3, "preview": "B"})),
    ]);
    assert_eq!(decorated(&hub2, key)["preview"], "B");
    let a = hub2.resolve("a").unwrap();
    hub2.set_rules_answered(&a, Some(json!({"tool": "Bash"}))).unwrap();
    assert_eq!(decorated(&hub2, key)["preview"], "A");
}

#[tokio::test]
async fn closed_bookmark_timestamp_rewind_keeps_newest_sibling() {
    let hub = make_hub(vec![
        row("a", json!({"agentSessionId": "chat", "updatedAt": 2, "preview": "A"})),
        row("b", json!({"agentSessionId": "chat", "updatedAt": 3, "preview": "B"})),
    ]);
    hub.test_append_activity("a", "user_message", json!({"text": "prompt"}));
    hub.test_append_activity("b", "turn_result", json!({"status": "completed"}));
    let a = hub.resolve("a").unwrap();
    assert_eq!(decorated(&hub, "claude-code:chat")["preview"], "B");
    assert_eq!(hub.set_bookmark(&a, 1, true).await.unwrap(), vec![1]);
    assert_eq!(decorated(&hub, "claude-code:chat")["preview"], "B");
}

#[test]
fn shared_batch_rechecks_expiry_for_live_tags_and_archived_parents() {
    let hub = make_hub(vec![
        row("root", json!({"status": "idle"})),
        row("child", json!({"status": "idle", "tags": {"spawnedBy": {"value": "root"}}})),
    ]);
    let child = hub.resolve("child").unwrap();
    let batch = Arc::new(Vec::new());
    let mut chat = json!({"key": "claude-code:child"});
    hub.chat_activity_for_batch(&batch).decorate(&mut chat);
    assert_eq!(chat["parent"], "claude-code:root");
    hub.set_tags(
        &child,
        Some(&serde_json::Map::from_iter([("spawnedBy".to_owned(), json!("root"))])),
        &[],
        Some(1),
    );
    let mut chat = json!({"key": "claude-code:child"});
    hub.chat_activity_for_batch(&batch).decorate(&mut chat);
    assert_eq!(chat["parent"], "claude-code:root");

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    // A one-second TTL is measured from the mutation; wait against the observed tag expiry.
    let expiry = child.meta().tags["spawnedBy"].expires_at.unwrap();
    while crate::store::now_ms() < expiry {
        assert!(std::time::Instant::now() < deadline, "tag expiry did not advance");
        std::thread::yield_now();
    }
    let mut chat = json!({"key": "claude-code:child"});
    hub.chat_activity_for_batch(&batch).decorate(&mut chat);
    assert_eq!(chat["parent"], Value::Null);

    let hub = make_hub(vec![
        row("root", json!({"status": "idle"})),
        row("child", json!({"status": "idle", "tags": {"spawnedBy": {"value": "root"}}})),
    ]);
    let root = hub.resolve("root").unwrap();
    let batch = Arc::new(Vec::new());
    let mut chat = json!({"key": "claude-code:child"});
    hub.chat_activity_for_batch(&batch).decorate(&mut chat);
    assert_eq!(chat["parent"], "claude-code:root");
    hub.set_tags(
        &root,
        Some(&serde_json::Map::from_iter([("archived".to_owned(), json!(true))])),
        &[],
        Some(1),
    );
    let expiry = root.meta().tags["archived"].expires_at.unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    let mut chat = json!({"key": "claude-code:child"});
    hub.chat_activity_for_batch(&batch).decorate(&mut chat);
    assert_eq!(chat["parent"], Value::Null);
    while crate::store::now_ms() < expiry {
        assert!(std::time::Instant::now() < deadline, "tag expiry did not advance");
        std::thread::yield_now();
    }
    let mut chat = json!({"key": "claude-code:child"});
    hub.chat_activity_for_batch(&batch).decorate(&mut chat);
    assert_eq!(chat["parent"], "claude-code:root");
}

#[test]
fn activity_cache_is_bounded_under_mutation_and_keeps_the_last_update() {
    let hub = make_hub(vec![row("live", json!({"status": "idle", "preview": "old"}))]);
    hub.chat_activity_cache.test_reset_builds();
    let stop = Arc::new(AtomicBool::new(false));
    let mutator = {
        let hub = hub.clone();
        let stop = stop.clone();
        thread::spawn(move || {
            for _ in 0..32 {
                hub.test_set_status("live", SessionStatus::Running);
                hub.test_set_status("live", SessionStatus::Waiting);
                thread::yield_now();
            }
            stop.store(true, Ordering::Release);
        })
    };
    let mut readers = Vec::new();
    let shared_batch = Arc::new(Vec::new());
    for n in 0..8 {
        let hub = hub.clone();
        let batch = shared_batch.clone();
        readers.push(thread::spawn(move || {
            let mut chat = json!({"key": "claude-code:live"});
            hub.chat_activity_for_batch(&batch).decorate(&mut chat);
            assert_eq!(chat["key"], "claude-code:live");
            n
        }));
    }
    for reader in readers {
        reader.join().unwrap();
    }
    mutator.join().unwrap();
    assert!(stop.load(Ordering::Acquire));
    let before = hub.chat_activity_cache.test_builds();
    let batch = Arc::new(Vec::new());
    let mut chat = json!({"key": "claude-code:live"});
    hub.chat_activity_for_batch(&batch).decorate(&mut chat);
    assert_eq!(chat["attention"], "needsInput");
    assert!(hub.chat_activity_cache.test_builds() <= before + 1);
}

#[test]
fn activity_cache_follows_live_status_transitions() {
    let hub = make_hub(vec![row("live", json!({"status": "idle", "preview": "old"}))]);
    let decorate = |hub: &Hub| {
        let mut chat = json!({"key": "claude-code:live"});
        hub.chat_activity_for_batch(&Arc::new(Vec::new())).decorate(&mut chat);
        chat
    };
    assert_eq!(decorate(&hub)["attention"], Value::Null);
    hub.test_append_activity("live", "message", json!({}));
    hub.test_set_status("live", SessionStatus::Waiting);
    assert_eq!(decorate(&hub)["attention"], "needsInput");
    hub.test_set_status("live", SessionStatus::Running);
    assert_eq!(decorate(&hub)["attention"], Value::Null);
    hub.test_set_status("live", SessionStatus::Closed);
    assert_eq!(decorate(&hub)["attention"], Value::Null);
    hub.test_set_status("live", SessionStatus::Idle);
    assert_eq!(decorate(&hub)["attention"], Value::Null);
}

#[test]
fn activity_batch_does_not_keep_expired_parent_relationship() {
    let expires = crate::store::now_ms() + 50;
    let hub = make_hub(vec![
        row("root", json!({})),
        row("child", json!({"tags": {"spawnedBy": {"value": "root", "expires_at": expires}}})),
    ]);
    let batch = Arc::new(Vec::new());
    let decorate = |hub: &Hub| {
        let mut chat = json!({"key": "claude-code:child"});
        hub.chat_activity_for_batch(&batch).decorate(&mut chat);
        chat
    };
    assert_eq!(decorate(&hub)["parent"], "claude-code:root");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while crate::store::now_ms() < expires {
        assert!(std::time::Instant::now() < deadline, "tag expiry did not advance");
        std::thread::yield_now();
    }
    assert_eq!(decorate(&hub)["parent"], Value::Null);
}

#[test]
fn closed_snapshot_does_not_publish_a_session_reopened_during_build() {
    let hub =
        make_hub(vec![row("closed", json!({"status": "closed", "preview": "before reopen"}))]);
    let entered = Arc::new(std::sync::Barrier::new(2));
    let release = Arc::new(std::sync::Barrier::new(2));
    hub.chat_activity_cache.test_pause_next_build(entered.clone(), release.clone());
    hub.chat_activity_cache.test_reset_builds();

    let building = {
        let hub = hub.clone();
        thread::spawn(move || hub.chat_activity())
    };
    entered.wait();
    assert!(hub.test_reopen("closed"));
    release.wait();
    let _stale = building.join().unwrap();

    assert_eq!(hub.chat_activity_cache.test_builds(), 1);
    assert!(!hub.chat_activity_cache.test_cached_closed("closed"));
    let _fresh = hub.chat_activity();
    assert_eq!(hub.chat_activity_cache.test_builds(), 2);
}
