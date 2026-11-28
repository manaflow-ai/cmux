use super::*;
use serde_json::json;

#[test]
fn the_built_in_file_loads_at_this_builds_revision() {
    let compat = compat().expect("spec/acpmux-abi.compat.json loads");
    assert_eq!(compat.current(), crate::protocol::ABI);
}

#[test]
fn only_an_older_covered_peer_is_translated() {
    let ours = crate::protocol::ABI;
    assert_eq!(target(None), None, "a peer from before the hello is served as it always was");
    assert_eq!(target(Some(ours)), None);
    assert_eq!(target(Some(ours + 1)), None, "a newer peer reads this build's messages");
    assert_eq!(target(Some(0)), None, "older than the file's base: nothing to write it down to");
    assert_eq!(target(Some(1)), Some(1));
}

#[test]
fn a_rev_1_reader_gets_the_removed_to_do_list_as_its_default() {
    let mut params = json!({"session": {"id": "s1", "turn": {"state": "idle"}}});
    assert!(down_event("_acpmux/session_changed", 1, &mut params));
    assert_eq!(
        params,
        json!({"session": {"id": "s1", "taskList": null, "turn": {"state": "idle", "planStep": null}}})
    );
}

#[test]
fn a_result_is_written_down_under_data() {
    let mut result = json!({"sessions": [{"id": "a"}, {"id": "b", "turn": {}}]});
    assert!(down_result("_acpmux/sessions", 1, &mut result));
    assert_eq!(
        result,
        json!({"sessions": [
            {"id": "a", "taskList": null},
            {"id": "b", "taskList": null, "turn": {"planStep": null}},
        ]})
    );
}

#[test]
fn a_message_no_rule_names_is_left_as_it_was() {
    let mut params = json!({"sessionId": "s1", "update": {"text": "hi"}});
    let before = params.clone();
    assert!(!down_event("session/update", 1, &mut params));
    assert_eq!(params, before);
    assert!(!changes("event:session/update", 1));
    assert!(changes("event:_acpmux/session_changed", 1));
    assert!(!changes("event:_acpmux/session_changed", crate::protocol::ABI));
}

#[test]
fn a_member_the_peer_has_is_kept() {
    let mut params = json!({"session": {"id": "s1", "taskList": []}});
    down_event("_acpmux/session_changed", 1, &mut params);
    assert_eq!(params["session"]["taskList"], json!([]));
}

fn memory_hub() -> std::sync::Arc<crate::hub::Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    crate::hub::Hub::new(cfg, store)
}

/// Over a real socket: a client whose hello says revision 1 reads the session list with the
/// to-do list rev 2 removed in its place (its default, `null`); one at this build's revision
/// reads the list as this build writes it.
#[tokio::test]
async fn an_older_client_reads_the_list_written_down_to_its_revision() {
    use crate::rpc::method;
    let hub = memory_hub();
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": "abi-down-1", "name": "a",
        "harness": "codex", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2});
    hub.insert_test_session(serde_json::from_value(meta).unwrap());
    let dir = cmux_unix_socket::short_test_dir("acpmux-abi-down");
    let path = dir.path().join("d.sock");
    let listener = crate::server::bind_unix(&path).await.unwrap();
    tokio::spawn(crate::server::serve_unix(hub, listener));

    let row = |list: &Value| {
        list.pointer("/sessions")
            .and_then(Value::as_array)
            .and_then(|rows| rows.iter().find(|r| r["sessionId"] == json!("abi-down-1")).cloned())
            .unwrap_or_else(|| panic!("no row in {list}"))
    };
    let same = crate::client::Client::connect(&path).await.unwrap();
    let list = same.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert!(row(&list).get("taskList").is_none(), "{list}");

    let older = crate::client::Client::connect(&path).await.unwrap();
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {},
        "clientInfo": {"name": "abi-older-test"}, "_meta": {"acpmux": {"abi": 1, "build": "old"}}});
    older.request(method::INITIALIZE, hello).await.unwrap();
    let list = older.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert_eq!(row(&list).get("taskList"), Some(&Value::Null), "{list}");
}
