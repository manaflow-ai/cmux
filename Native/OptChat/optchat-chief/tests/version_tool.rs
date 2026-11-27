//! The Chief's `version` tool (Lawrence 2026-10-20: "make sure chief can
//! detect cmux version and stuff like that"): one read-only call answers the
//! cmux CLI and app (`cmux version --json`: version, nightly build, channel,
//! build sha, bundle, update state, acpmux and other helpers, macOS) and the
//! Chief's own host and engine (the harness CLI each role runs).

use optchat_chief::engine::{ResolvedEngine, ResolvedHarness, save_resolved};
use optchat_chief::mcp::{Backend, handle, tools_for};
use optchat_chief::tools::Call;
use optchat_chief::version_tool::report;
use serde_json::{Value, json};

fn cmux_report() -> Value {
    json!({
        "cli": {"version": "1.0.0", "build_commit": "c6a351b9205780cd8c27cdcb0a7876d4410a7acb"},
        "app": {"name": "cmux-next", "version": "1.0.0-nightly.3937488754201", "channel": "nightly",
                "bundle_id": "com.cmuxterm.app.nightly"},
        "cli_matches_app": true,
        "updates": {"phase": "idle", "ready": "ready", "last_check": "2026-10-20T06:30:00Z"},
        "components": {"acpmux": {"commit": "f4c2e8298457235eb75783ce3f6c73f55e326d28"}},
        "os": {"name": "macOS", "version": "26.1"},
    })
}

fn engine_home() -> tempfile::TempDir {
    let home = tempfile::tempdir().unwrap();
    let harness = |name: &str, version: &str| ResolvedHarness {
        harness: name.to_owned(),
        kind: "claude".to_owned(),
        argv0: format!("/opt/bin/{name}"),
        version: version.to_owned(),
    };
    save_resolved(
        home.path(),
        &ResolvedEngine {
            turn: Some(harness("claude-sr2", "2.1.303 (Claude Code)")),
            compactor: None,
            subagent: Some(harness("claude", "2.1.300 (Claude Code)")),
        },
    )
    .unwrap();
    home
}

/// The report joins the cmux report as given with the Chief's own version
/// and the engine its host resolved.
#[test]
fn the_report_joins_cmux_with_the_chief_and_its_engine() {
    let home = engine_home();
    let value = report(&|| Ok(cmux_report()), home.path());
    assert_eq!(
        value["cmux"]["app"]["version"],
        "1.0.0-nightly.3937488754201"
    );
    assert_eq!(value["cmux"]["app"]["channel"], "nightly");
    assert_eq!(
        value["cmux"]["cli"]["build_commit"],
        "c6a351b9205780cd8c27cdcb0a7876d4410a7acb"
    );
    assert_eq!(value["cmux"]["updates"]["ready"], "ready");
    assert_eq!(
        value["cmux"]["components"]["acpmux"]["commit"],
        "f4c2e8298457235eb75783ce3f6c73f55e326d28"
    );
    assert_eq!(value["cmux"]["os"]["version"], "26.1");
    assert_eq!(value["chief"]["version"], env!("CARGO_PKG_VERSION"));
    assert!(value["chief"]["path"].is_string(), "{value}");
    assert_eq!(
        value["chief"]["engine"]["turn"]["version"],
        "2.1.303 (Claude Code)"
    );
    assert_eq!(value["chief"]["engine"]["turn"]["harness"], "claude-sr2");
    assert_eq!(
        value["chief"]["engine"]["subagent"]["argv0"],
        "/opt/bin/claude"
    );
}

/// A cmux CLI that fails (no app, an old CLI without `version`) still gives
/// the Chief's side, with the reason in place of the cmux report.
#[test]
fn a_failing_cmux_still_reports_the_chief() {
    let home = tempfile::tempdir().unwrap();
    let value = report(
        &|| Err("cmux: unknown resource scope \"version\"".to_owned()),
        home.path(),
    );
    assert_eq!(
        value["cmux"]["error"],
        "cmux: unknown resource scope \"version\""
    );
    assert_eq!(value["chief"]["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(
        value["chief"]["engine"],
        Value::Null,
        "no host resolved one"
    );
}

struct Fake;

impl Backend for Fake {
    fn call(&self, _call: Call) -> Result<String, String> {
        Err("the version tool never reaches the host".to_owned())
    }
    fn version(&self) -> Result<String, String> {
        Ok("{\"chief\":{\"version\":\"9.9.9\"}}".to_owned())
    }
}

struct FakeSubagent;

impl Backend for FakeSubagent {
    fn call(&self, _call: Call) -> Result<String, String> {
        Err("the version tool never reaches the host".to_owned())
    }
    fn subagent(&self) -> bool {
        true
    }
    fn version(&self) -> Result<String, String> {
        Ok("{}".to_owned())
    }
}

fn names(tools: &Value) -> Vec<String> {
    tools
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_owned())
        .collect()
}

/// The Chief and its subagents both list `version`, read-only, no arguments.
#[test]
fn chief_and_subagents_list_the_version_tool() {
    for subagent in [false, true] {
        let tools = tools_for(subagent);
        assert!(
            names(&tools).iter().any(|n| n == "version"),
            "subagent={subagent}: {:?}",
            names(&tools)
        );
        let tool = tools
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["name"] == "version")
            .unwrap();
        assert_eq!(tool["inputSchema"]["properties"], json!({}));
        let description = tool["description"].as_str().unwrap();
        assert!(description.contains("update state"), "{description}");
        assert!(description.contains("engine"), "{description}");
    }
}

/// `tools/call version` answers from the backend's version report, for the
/// Chief and a subagent alike.
#[test]
fn the_version_call_answers_the_report() {
    let call = json!({"jsonrpc": "2.0", "id": 7, "method": "tools/call",
        "params": {"name": "version", "arguments": {}}});
    let answer = handle(&call, &Fake).unwrap();
    assert_eq!(answer["result"]["isError"], false, "{answer}");
    assert_eq!(
        answer["result"]["content"][0]["text"],
        "{\"chief\":{\"version\":\"9.9.9\"}}"
    );
    let answer = handle(&call, &FakeSubagent).unwrap();
    assert_eq!(answer["result"]["isError"], false, "{answer}");
}

/// The tool only reads: a remote-origin turn runs it without asking.
#[test]
fn the_version_tool_needs_no_approval() {
    let request = json!({"toolCall": {"_meta": {"claude": {"tool": "mcp__optchat__version"}}}});
    assert!(optchat_chief::approval::is_memory_tool(&request));
    assert!(optchat_chief::chief_profile::Grant::from_mcp_value(Some("none")).allows("version"));
}
