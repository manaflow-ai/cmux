//! The tool contract (cloud-chief-durable-DESIGN.md section 13, export 2):
//! the tool list the host's MCP server offers today (golden files written
//! from optchat-chief at 53593ff05b8), the per-engine specs with replay
//! flags for the Cloud Chief, and `call_pure` for the memory tools.

use chief_kernel::call_pure;
use chief_kernel::tools::{specs, tool_list};
use optchat_core::{Kind, Memory, NodeId, Store};
use serde_json::{Value, json};

fn golden(name: &str) -> Value {
    let path = format!(
        "{}/tests/golden/tools/{name}.json",
        env!("CARGO_MANIFEST_DIR")
    );
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

/// The host's grant with no record: every tool but profile and chiefs.
fn no_record(tool: &str) -> bool {
    !matches!(tool, "profile" | "chiefs")
}

#[test]
fn the_list_is_the_one_the_host_offers_today() {
    assert_eq!(tool_list(false, &no_record), golden("chief"));
    assert_eq!(tool_list(true, &no_record), golden("subagent"));
}

fn names(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn pi_durable_gets_every_tool_its_host_can_do_with_a_replay_flag() {
    let s = specs("pi-durable", "{}").unwrap();
    let n = names(&s);
    for want in [
        "zoom",
        "date",
        "spawn",
        "tell",
        "control",
        "send",
        "reply",
        "react",
        "stop",
        "sleep",
        "remember",
        "transcript",
    ] {
        assert!(n.contains(&want.to_owned()), "{want} missing: {n:?}");
    }
    // Host-only: the Mac's app, moving a Mac home and a command off the turn.
    for host_only in ["version", "move", "watch"] {
        assert!(!n.contains(&host_only.to_owned()), "{host_only}: {n:?}");
    }
    for t in s.as_array().unwrap() {
        assert!(
            t["description"].as_str().is_some_and(|d| !d.is_empty()),
            "{t}"
        );
        assert_eq!(t["json_schema"]["type"], "object", "{t}");
        assert!(matches!(t["replay"].as_str(), Some("safe" | "once")), "{t}");
    }
    let replay = |name: &str| {
        s.as_array()
            .unwrap()
            .iter()
            .find(|t| t["name"] == name)
            .unwrap()["replay"]
            .clone()
    };
    // Reads and keyed, deduped posts are safe to run again; a spawn or a wake is not.
    assert_eq!(replay("zoom"), "safe");
    assert_eq!(replay("send"), "safe");
    assert_eq!(replay("spawn"), "once");
    assert_eq!(replay("sleep"), "once");
}

#[test]
fn a_grant_keeps_only_what_it_names_and_the_memory_tools() {
    let s = specs("pi-durable", r#"{"tools": ["tell"]}"#).unwrap();
    let n = names(&s);
    assert!(
        n.contains(&"tell".to_owned()) && n.contains(&"control".to_owned()),
        "{n:?}"
    );
    assert!(!n.contains(&"spawn".to_owned()), "{n:?}");
    assert!(
        n.contains(&"zoom".to_owned()) && n.contains(&"send".to_owned()),
        "{n:?}"
    );
    assert!(specs("no-such-engine", "{}").is_err());
}

struct Msgs(Vec<(Kind, String)>);

impl Store for Msgs {
    fn message(&self, i: u64) -> (Kind, String) {
        self.0[i as usize].clone()
    }
    fn node(&self, _id: NodeId) -> Option<String> {
        None
    }
}

#[test]
fn call_pure_answers_zoom_and_date_from_the_memory_and_the_context() {
    let store = Msgs(vec![
        (Kind::User, "fix the sidebar".into()),
        (Kind::Talk, "a12 is on it".into()),
    ]);
    let mut memory = Memory::new(64_000);
    memory.append_in(&store);
    memory.append_in(&store);
    let dates = |id: u64| (id == 1).then(|| "2026-10-27T18:02:11.000-07:00".to_owned());
    let ctx = json!({"now_ms": 0, "utc_offset_minutes": 60}).to_string();
    let zoomed = call_pure(
        "zoom",
        r#"{"id": 1, "n": 1}"#,
        &ctx,
        &memory,
        &store,
        &dates,
    )
    .unwrap();
    assert!(zoomed.contains("a12 is on it"), "{zoomed}");
    // The person's offset (UTC+01:00) from ctx, not the machine's.
    let date = call_pure("date", r#"{"id": 1}"#, &ctx, &memory, &store, &dates).unwrap();
    assert_eq!(date, "2026-10-28 02:02:11 +01:00");
    // As the host answers a message with no stored date.
    assert_eq!(
        call_pure("date", r#"{"id": 0}"#, &ctx, &memory, &store, &dates).unwrap(),
        "No message 0."
    );
    assert!(
        call_pure("send", r#"{"text": "x"}"#, &ctx, &memory, &store, &dates).is_err(),
        "send is no pure tool"
    );
}

#[test]
fn a_mac_engine_gets_watch_and_never_replays_it() {
    for engine in ["native", "claude", "codex"] {
        let s = specs(engine, "{}").unwrap();
        let watch = s
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["name"] == "watch")
            .unwrap_or_else(|| panic!("{engine} has no watch"));
        assert_eq!(watch["replay"], "once", "{engine}");
        let props = &watch["json_schema"]["properties"];
        for key in ["command", "until", "timeout_seconds", "note", "cancel"] {
            assert!(props.get(key).is_some(), "{engine}: {key}");
        }
    }
}
