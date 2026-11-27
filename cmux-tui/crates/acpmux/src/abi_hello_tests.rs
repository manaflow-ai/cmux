use super::*;
use crate::client::Client;
use crate::config::{Config, StoreMode};
use crate::rpc::method;

fn memory_hub() -> std::sync::Arc<crate::hub::Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    crate::hub::Hub::new(cfg, store)
}

#[test]
fn the_revision_is_the_gates_newest() {
    assert_eq!(parse_revision(r#"{"base": 1, "revisions": []}"#), (1, 1));
    assert_eq!(parse_revision(r#"{"base": 1, "revisions": [{"rev": 2}, {"rev": 4}]}"#), (1, 4));
    assert_eq!(parse_revision("not json"), (1, 1));
    // The committed file: one revision past the base when this test was written; it only grows.
    let (base, rev) = revision();
    assert_eq!(base, 1);
    assert!(rev >= 2, "{rev}");
}

#[test]
fn a_hello_is_read_and_never_fails() {
    let (_, ours) = revision();
    let hello = |meta: Value| json!({"clientInfo": {"name": "x"}, "_meta": {"acpmux": meta}});
    assert_eq!(skew(read(&hello(json!({}))).rev), Skew::PreHello);
    assert_eq!(skew(read(&hello(json!({"abi": "two"}))).rev), Skew::PreHello);
    assert_eq!(skew(read(&hello(json!({"abi": {"rev": -1}}))).rev), Skew::PreHello);
    assert_eq!(skew(read(&hello(json!({"abi": {"rev": 0}}))).rev), Skew::Older);
    assert_eq!(skew(read(&hello(json!({"abi": {"rev": ours}}))).rev), Skew::Same);
    assert_eq!(skew(read(&hello(json!({"abi": {"rev": ours + 9}}))).rev), Skew::Newer);
    let long = "b".repeat(500);
    let read_long = read(&hello(json!({"build": long})));
    assert_eq!(read_long.build.map(|b| b.len()), Some(64));
    // The daemon's result names itself in agentInfo.
    let result = json!({"agentInfo": {"name": "acpmux"}, "_meta": {"acpmux": {"abi": own(), "build": "b1"}}});
    assert_eq!(
        read(&result),
        Hello { client: "acpmux".into(), rev: Some(ours), build: Some("b1".into()) }
    );
}

/// Over a real socket: the daemon answers its `abi` and `build`; the CLI client says its own and
/// reads the daemon's; a pre-hello client, a newer one and a malformed one all initialize, and
/// `_acpmux/status` counts each with its skew.
#[tokio::test]
async fn old_and_new_peers_initialize_and_status_counts_them() {
    let hub = memory_hub();
    let dir = cmux_unix_socket::short_test_dir("acpmux-abi");
    let path = dir.path().join("d.sock");
    let listener = crate::server::bind_unix(&path).await.unwrap();
    tokio::spawn(crate::server::serve_unix(hub, listener));
    let client = Client::connect(&path).await.unwrap();
    let (_, ours) = revision();
    assert_eq!(client.daemon_abi_rev(), Some(ours));

    let name = format!("abi-test-{}", std::process::id());
    let hello = |meta: Value| {
        json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": name},
            "_meta": {"acpmux": meta}})
    };
    for meta in [
        json!({}),
        json!({"abi": {"rev": ours + 5, "base": 1}, "build": "future"}),
        json!({"abi": [1, 2], "build": 7}),
    ] {
        let init = client.request(method::INITIALIZE, hello(meta.clone())).await.unwrap();
        assert_eq!(init.pointer("/_meta/acpmux/abi"), Some(&own()), "{meta}: {init}");
        assert_eq!(
            init.pointer("/_meta/acpmux/build").and_then(Value::as_str),
            Some(crate::hub::build())
        );
    }

    let status = client.request(method::MUX_STATUS, json!({})).await.unwrap();
    assert_eq!(status.pointer("/abi/rev"), Some(&json!(ours)), "{status}");
    let peers = status.pointer("/abi/peers").and_then(Value::as_array).unwrap();
    let mine = |skew: &str| {
        peers
            .iter()
            .filter(|p| p["client"] == json!(name) && p["skew"] == json!(skew))
            .map(|p| p["hellos"].as_u64().unwrap())
            .sum::<u64>()
    };
    // The empty and the malformed hello are both pre-hello; the future one is newer.
    assert_eq!(mine("pre-hello"), 2, "{status}");
    assert_eq!(mine("newer"), 1, "{status}");
    // The CLI's own hello is counted the same: this build, same revision.
    assert!(
        peers.iter().any(|p| p["client"] == json!("acpmux-cli")
            && p["skew"] == json!("same")
            && p["build"] == json!(crate::hub::build())),
        "{status}"
    );
}
