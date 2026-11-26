use super::*;
use crate::client::Client;
use crate::config::{Config, StoreMode};
use serde_json::{Value, json};
use std::collections::BTreeSet;

#[test]
fn every_id_is_stable_shaped_and_listed_once() {
    let mut seen = BTreeSet::new();
    for id in ids() {
        let (name, version) = id
            .rsplit_once("-v")
            .or_else(|| id.rsplit_once(".v"))
            .unwrap_or_else(|| panic!("{id} has no version suffix"));
        assert!(
            !name.is_empty()
                && name.bytes().all(|b| b.is_ascii_lowercase()
                    || b.is_ascii_digit()
                    || b == b'-'
                    || b == b'.')
                && !version.is_empty()
                && version.bytes().all(|b| b.is_ascii_digit()),
            "{id} is not a lowercase-kebab id ending in -vN"
        );
        assert!(seen.insert(id), "{id} is listed twice");
    }
    assert_eq!(ids().first(), Some(&"acpmux-v1"), "the base comes first");
}

fn begin_manifest() -> Value {
    json!({"files": [
        {"path": "session.json", "size": 10},
        {"path": "events/000001.ndjson", "size": 20},
        {"path": "composers.json", "size": 2},
        {"path": format!("attachments/{}", "ab".repeat(32)), "size": 3},
        {"path": "native/claude-project/.claude/projects/p/s.jsonl", "size": 4},
    ]})
}

fn paths(manifest: &Value) -> Vec<&str> {
    manifest["files"].as_array().unwrap().iter().map(|f| f["path"].as_str().unwrap()).collect()
}

/// A target from before the optional files (it lists neither id) gets the chat without
/// them, every required file still listed, and the move says so in one line.
#[test]
fn an_older_target_gets_the_move_without_its_optional_files() {
    let mut manifest = begin_manifest();
    let left = leave_out_untaken(&mut manifest, |_| false);
    assert_eq!(left, vec!["composers.json".to_owned(), format!("attachments/{}", "ab".repeat(32))]);
    assert_eq!(
        paths(&manifest),
        [
            "session.json",
            "events/000001.ndjson",
            "native/claude-project/.claude/projects/p/s.jsonl"
        ]
    );
    let line = left_out_line(&left).unwrap();
    assert!(line.contains("unsent composer text") && line.contains("prompt images"), "{line}");
}

/// A current target lists both ids (this build does): the move carries every file.
#[test]
fn a_current_target_gets_every_file() {
    let mut manifest = begin_manifest();
    let here = ids();
    let left = leave_out_untaken(&mut manifest, |c| here.contains(&c));
    assert!(left.is_empty());
    assert_eq!(left_out_line(&left), None);
    assert_eq!(paths(&manifest), paths(&begin_manifest()));
    for (capability, _) in OPTIONAL_BUNDLE_FILES {
        assert!(here.contains(capability), "{capability} is not listed");
    }
}

/// A target that lists only one id loses only the other's files.
#[test]
fn a_target_is_sent_each_optional_file_it_lists() {
    let mut manifest = begin_manifest();
    let left = leave_out_untaken(&mut manifest, |c| c == TRANSFER_COMPOSERS);
    assert_eq!(left.len(), 1);
    assert!(left[0].starts_with("attachments/"));
    assert!(paths(&manifest).contains(&"composers.json"));
}

/// Only the listed optional files are ever left out: an unknown file stays in the manifest,
/// so a guarded target still refuses it (`hub/transfer_guard.rs`).
#[test]
fn an_unknown_file_is_never_left_out() {
    assert_eq!(optional_bundle_file("harness/owner.sqlite"), None);
    assert_eq!(optional_bundle_file("composers.json.bak"), None);
    assert_eq!(optional_bundle_file("x/composers.json"), None);
    let mut manifest = json!({"files": [{"path": "harness/owner.sqlite", "size": 1}]});
    assert!(leave_out_untaken(&mut manifest, |_| false).is_empty());
    assert_eq!(paths(&manifest), ["harness/owner.sqlite"]);
}

/// An id covers names the daemon has: a renamed or removed method breaks
/// this test, not the pane that relied on the id.
#[test]
fn every_covered_name_is_in_the_protocol_registry() {
    let registry: BTreeSet<&str> =
        crate::protocol::registry().iter().map(|decl| decl.name).collect();
    for capability in CAPABILITIES {
        // Machine onboarding is CLI-only and has no daemon wire method.
        if capability.id == "machine.join.stdin.v1" || capability.id == DAEMON_SERVICE_APP {
            assert!(capability.wire.is_empty());
            continue;
        }
        assert!(!capability.wire.is_empty(), "{} covers nothing", capability.id);
        for name in capability.wire {
            assert!(
                registry.contains(name),
                "{} covers {name}, which acpmux does not serve",
                capability.id
            );
        }
    }
}

#[test]
fn base_info_and_carrier_methods_have_wire_declarations_in_every_build() {
    let wire = |id| CAPABILITIES.iter().find(|cap| cap.id == id).unwrap().wire;
    assert!(wire("acpmux-v1").contains(&method::MUX_INFO));
    assert!(wire(INFO_ROWS).contains(&method::MUX_INFO));
    assert_eq!(
        wire(MACHINE_ROUTES),
        &[method::MUX_MACHINE_ROUTES, method::MUX_MACHINE_ROUTE_PROBE]
    );
    assert_eq!(wire(REMOTE_PIPE), &[method::MUX_REMOTE_PIPE]);
}

fn memory_hub() -> std::sync::Arc<crate::hub::Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    crate::hub::Hub::new(cfg, store)
}

#[tokio::test]
async fn declared_agent_passthroughs_require_a_session() {
    let client = Client::in_process(memory_hub()).await.unwrap();
    for m in [method::MUX_SUBAGENT_STOP, method::MUX_STEER_WITHDRAW, method::MUX_STEP_NOW] {
        let error = client.request(m, json!({})).await.unwrap_err();
        let rpc = &error.downcast_ref::<crate::client::DaemonError>().unwrap().0;
        assert_eq!((rpc.code, rpc.message.as_str()), (-32602, "sessionId is required"), "{m}");
    }
    let unknown = client.request("_acpmux/unknown", json!({})).await.unwrap_err();
    assert_eq!(unknown.downcast_ref::<crate::client::DaemonError>().unwrap().0.code, -32601);
}

/// `initialize` and `_acpmux/status` carry the list, and `acpmux
/// capabilities --json` prints the same one without a daemon.
#[tokio::test]
async fn initialize_status_and_the_cli_name_the_same_capabilities() {
    let hub = memory_hub();
    let dir = cmux_unix_socket::short_test_dir("acpmux-caps");
    let path = dir.path().join("d.sock");
    let listener = crate::server::bind_unix(&path).await.unwrap();
    let channel = Client::in_process(hub.clone()).await.unwrap();
    tokio::spawn(crate::server::serve_unix(hub, listener));
    let client = Client::connect(&path).await.unwrap();

    let carrier = cfg!(feature = "hub-carrier");
    assert_eq!(client.daemon_lists(MACHINE_ROUTES), carrier);
    assert_eq!(channel.daemon_lists(MACHINE_ROUTES), carrier);
    assert_eq!(client.daemon_lists(REMOTE_PIPE), carrier);
    assert!(!channel.daemon_lists(REMOTE_PIPE));

    let expected = json!(ids());
    let status = client.request(method::MUX_STATUS, json!({})).await.unwrap();
    assert_eq!(status["capabilities"], expected, "{status}");
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "caps-test"}});
    let init = client.request(method::INITIALIZE, hello).await.unwrap();
    assert_eq!(init.pointer("/_meta/acpmux/capabilities"), Some(&expected), "{init}");
    assert!(client.daemon_lists(TRIGGER_CHAT), "trigger chat capability must gate its CLI helper");

    let printed: Value = serde_json::from_str(&render(true)).unwrap();
    assert_eq!(printed, json!({"capabilities": expected}));
    assert_eq!(render(false), ids().iter().map(|id| format!("{id}\n")).collect::<String>());
}
