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

/// An id covers names the daemon has: a renamed or removed method breaks
/// this test, not the pane that relied on the id.
#[test]
fn every_covered_name_is_in_the_protocol_registry() {
    let registry: BTreeSet<&str> =
        crate::protocol::registry().iter().map(|decl| decl.name).collect();
    for capability in CAPABILITIES {
        // Machine onboarding is CLI-only and has no daemon wire method.
        if capability.id == "machine.join.stdin.v1" {
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

/// `initialize` and `_acpmux/status` carry the list, and `acpmux
/// capabilities --json` prints the same one without a daemon.
#[tokio::test]
async fn initialize_status_and_the_cli_name_the_same_capabilities() {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    let dir = cmux_unix_socket::short_test_dir("acpmux-caps");
    let path = dir.path().join("d.sock");
    let listener = crate::server::bind_unix(&path).await.unwrap();
    tokio::spawn(crate::server::serve_unix(hub, listener));
    let client = Client::connect(&path).await.unwrap();

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
