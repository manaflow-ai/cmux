//! The compactor's acpmux route against the fake acpmux port: one session
//! per node with a deny-all policy and its own required preset, in a slot
//! working directory outside the home, the size loop in the same session,
//! the session killed and its transcript deleted when the node is done or
//! failed, at most COMPACTOR_SESSIONS sessions across the main and fallback compactors,
//! refusals as acpmux really sends them, and the route chosen by the endpoint.

mod common;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::brain::Input;
use optchat_chief::compactor::COMPACTOR_SESSIONS;
use optchat_chief::compactor::{
    AcpmuxCompactor, COMPACTOR_ARGS, CompactRoute, CompactorSpec, DENIED_TOOLS, POLICY, Slots,
    cached_prompt, compact_route, compactor_presets, compactor_settings, compactor_spec,
    is_marker_limit_error, is_refusal_error, probe_models, project_dir_name, request_blocks,
    slot_preset, strip_preamble,
};
use optchat_chief::paths::Paths;
use optchat_host::{
    CompactModel, CompactRequest, Config, DEFAULT_BASE_URL, Kind, NodeId, OptChat, PROBE_NODE,
    SUBROUTER_KEY, SystemClock, probe, run_node,
};
use serde_json::{Value, json};

/// What acpmux answers when Claude Code ends a turn with stop reason
/// `refusal`: a JSON-RPC error (code -32603) whose message is Claude Code's
/// result text (acpmux `claude_stdio/inbound.rs`; text from Claude Code 2.1.289).
const REFUSAL: &str = "API Error: Claude Sonnet 5.5's safeguards flagged this message (https://www.anthropic.com/legal/aup). This sometimes happens with safe, normal conversations. Claude Code can't respond to this message with Claude Sonnet 5.5.\n\nTry rephrasing the request in a new session or change your model.\n\nLearn more: https://support.claude.com";

/// One fake turn that answers `text`.
fn answer(text: &str) -> Vec<Value> {
    vec![
        json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": text}}),
        ),
        json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
    ]
}

fn spec(dir: &std::path::Path) -> CompactorSpec {
    CompactorSpec {
        name: "optchat-compact-test".into(),
        work: dir.join("work"),
        transcript_dirs: vec![dir.join("compactor-claude"), dir.join("user-claude")],
        preset: "optchat-compact-test-preset".into(),
        harness: "claude-sr".into(),
        family: Family::Claude,
        codex_home: dir.join("codex"),
        model: Some("claude-sonnet-5-5".into()),
        effort: None,
        timeout: Duration::from_secs(30),
        chief: "h0me".into(),
        user_env: Default::default(),
    }
}

fn compactor(agents: &Arc<FakeAgents>, dir: &std::path::Path) -> AcpmuxCompactor {
    AcpmuxCompactor::new(agents.clone(), spec(dir), Slots::new(COMPACTOR_SESSIONS))
}

fn request(i: u64) -> CompactRequest {
    CompactRequest {
        node: NodeId::new(0, i),
        system: "SYS".into(),
        context: "<chat>\nuser: hi\n</chat>".into(),
        step: format!("STEP {i}"),
        cut: None,
    }
}

fn texts(blocks: &[Value]) -> Vec<String> {
    blocks
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default().to_owned())
        .collect()
}

#[test]
fn a_node_is_built_in_one_deny_all_session_that_is_then_purged() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: pasted a deploy log")));
    let compactor = Arc::new(compactor(&agents, dir.path()));
    let config = Config {
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    let system = config.prompt.text(&config.agent);
    let chat = OptChat::open_with(
        dir.path().join("chat"),
        config,
        compactor,
        Arc::new(SystemClock),
    )
    .unwrap();
    chat.append(Kind::User, &"deploy step; ".repeat(100))
        .unwrap();
    assert!(
        chat.settle(None, Some(WAIT)),
        "{:?}",
        chat.status().failures
    );
    assert!(
        chat.render_view()
            .text
            .contains("user: pasted a deploy log")
    );
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.specs.len(), 1);
    let s = &inner.specs[0];
    assert_eq!(s.policy, POLICY);
    let work = std::fs::canonicalize(dir.path().join("work")).unwrap();
    assert_eq!(
        s.cwd,
        work.join("slot-0"),
        "a slot directory, its real path"
    );
    assert_eq!(s.harness, "claude-sr");
    assert_eq!(s.model.as_deref(), Some("claude-sonnet-5-5"));
    assert_eq!(
        s.preset.as_deref(),
        Some("optchat-compact-test-preset-slot-0"),
        "the compactor names its slot's own preset, which acpmux must have"
    );
    assert_eq!(
        s.effort, None,
        "the spec's effort (here none) reaches the session"
    );
    assert!(s.name.starts_with("optchat-compact-test-"));
    // System text, then the context pieces, then the step (section 8's order).
    let blocks = texts(&inner.prompts[0]);
    assert_eq!(blocks[0], system);
    assert_eq!(blocks[1], "<chat>\n</chat>");
    assert!(blocks[2].starts_with("Compaction: compress message 0 into one line"));
    assert_eq!(blocks.len(), 3);
    assert_eq!(inner.ended, vec!["s1"], "the node's session is killed");
}

#[test]
fn the_size_loop_continues_in_the_same_session() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|turn, _| {
        if turn == 0 {
            answer(&"long".repeat(175))
        } else {
            answer("user: short now")
        }
    }));
    let compactor = compactor(&agents, dir.path());
    assert_eq!(
        run_node(&compactor, &request(3)).unwrap(),
        "user: short now"
    );
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.specs.len(), 1, "one session for the node");
    assert_eq!(inner.prompts.len(), 2);
    let retry = texts(&inner.prompts[1]);
    assert_eq!(retry.len(), 1, "a retry sends only the size message");
    assert!(
        retry[0].starts_with("Too long: your line is 700 bytes"),
        "{retry:?}"
    );
    assert_eq!(inner.ended, vec!["s1"]);
    assert_ne!(inner.prompt_ids[0], inner.prompt_ids[1]);
}

#[test]
fn a_failed_node_kills_its_session_and_a_refusal_is_reported_as_one() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("")));
    agents.inner.lock().unwrap().answer = Some(json!({"stopReason": "refusal"}));
    let compactor = compactor(&agents, dir.path());
    let error = run_node(&compactor, &request(0)).unwrap_err();
    assert!(error.refused, "{error:?}");
    assert_eq!(agents.inner.lock().unwrap().ended, vec!["s1"]);

    agents.inner.lock().unwrap().lose = true;
    let error = run_node(&compactor, &request(1)).unwrap_err();
    assert!(!error.refused);
    assert_eq!(agents.inner.lock().unwrap().ended, vec!["s1", "s2"]);
}

#[test]
fn at_most_jobs_compactor_sessions_live_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|turn, _| answer(&format!("user: node {turn}"))));
    agents.hold(true);
    let compactor = Arc::new(compactor(&agents, dir.path()));
    let extra = 3;
    let workers: Vec<_> = (0..(COMPACTOR_SESSIONS + extra) as u64)
        .map(|i| {
            let c = compactor.clone();
            std::thread::spawn(move || run_node(&*c, &request(i)))
        })
        .collect();
    agents.wait_prompts(COMPACTOR_SESSIONS);
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(
        agents.inner.lock().unwrap().specs.len(),
        COMPACTOR_SESSIONS,
        "the others wait for a free session slot"
    );
    agents.hold(false);
    agents.release();
    for w in workers {
        assert!(w.join().unwrap().is_ok());
    }
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.specs.len(), COMPACTOR_SESSIONS + extra);
    assert_eq!(inner.ended.len(), COMPACTOR_SESSIONS + extra);
}

#[test]
fn the_probe_builds_one_node_through_acpmux() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: ping")));
    let compactor = compactor(&agents, dir.path());
    assert_eq!(probe(&compactor, "SYS").unwrap(), "user: ping");
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.specs[0].name, "optchat-compact-test-probe");
    assert_eq!(inner.ended, vec!["s1"]);
    drop(inner);
    let _ = PROBE_NODE;
}

#[test]
fn request_blocks_keep_the_cache_shape() {
    let line = format!("{}\n", "x".repeat(99));
    let mut context = String::from("<chat>\n");
    for _ in 0..1_100 {
        context.push_str(&line);
    }
    context.push_str("</chat>");
    let r = CompactRequest {
        context: context.clone(),
        ..request(0)
    };
    let blocks = texts(&request_blocks(&r));
    assert_eq!(blocks[0], "SYS");
    assert_eq!(blocks.len(), 1 + 4 + 1, "system, four context pieces, step");
    assert_eq!(blocks[1..5].concat(), context);
    assert_eq!(blocks[5], "STEP 0");
}

#[test]
fn the_route_is_acpmux_on_the_subrouter_and_the_api_on_a_configured_endpoint() {
    let config = |base: &str, key: &str| Config {
        base_url: base.into(),
        api_key: key.into(),
        ..Config::default()
    };
    let sub = config(DEFAULT_BASE_URL, SUBROUTER_KEY);
    assert_eq!(compact_route(None, &sub), Ok(CompactRoute::Acpmux));
    let sub_with_key = config(&format!("{DEFAULT_BASE_URL}/"), "sk-mine");
    assert_eq!(compact_route(None, &sub_with_key), Ok(CompactRoute::Acpmux));
    let keyless = config("https://api.anthropic.com", SUBROUTER_KEY);
    assert_eq!(compact_route(None, &keyless), Ok(CompactRoute::Acpmux));
    // Purely local ACP: a configured key does not move the compactor off
    // acpmux; only OPTCHAT_COMPACTOR=api does.
    let real = config("https://api.anthropic.com", "sk-real");
    assert_eq!(compact_route(None, &real), Ok(CompactRoute::Acpmux));
    assert_eq!(compact_route(Some("api"), &sub), Ok(CompactRoute::Api));
    assert_eq!(
        compact_route(Some("acpmux"), &real),
        Ok(CompactRoute::Acpmux)
    );
    assert!(compact_route(Some("bogus"), &sub).is_err());
}

#[test]
fn a_notice_is_posted_once_when_the_conversation_is_known() {
    let mut h = Harness::new(default_script());
    let notice = || Input::Notice {
        key: "notice:compactor:1".into(),
        text: "The memory compactor cannot build summaries".into(),
    };
    h.brain.step(notice());
    assert!(
        h.owner.lock().unwrap().sends().is_empty(),
        "no conversation yet"
    );
    h.connect();
    h.brain.step(notice());
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(
        sends,
        vec![(
            "notice:compactor:1".to_owned(),
            "The memory compactor cannot build summaries".to_owned()
        )]
    );
}

// Audit round 3, M2: acpmux reports a refused Claude turn as a JSON-RPC
// error carrying Claude Code's text, never as `{stopReason: "refusal"}`.
#[test]
fn a_refusal_as_acpmux_sends_it_is_classified_as_refused() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("")));
    agents.inner.lock().unwrap().answer_error = Some(REFUSAL.into());
    let compactor = compactor(&agents, dir.path());
    let error = run_node(&compactor, &request(0)).unwrap_err();
    assert!(error.refused, "{error:?}");
    assert_eq!(agents.inner.lock().unwrap().ended, vec!["s1"]);

    agents.inner.lock().unwrap().answer_error =
        Some("Claude AI usage limit reached|1759600000".into());
    let error = run_node(&compactor, &request(1)).unwrap_err();
    assert!(
        !error.refused,
        "a usage limit is retried, not refused: {error:?}"
    );
}

#[test]
fn refusal_texts() {
    assert!(is_refusal_error(REFUSAL));
    assert!(is_refusal_error(
        "API Error: Claude Code is unable to respond to this request, which appears to violate our Usage Policy (https://www.anthropic.com/legal/aup). Please double press esc to edit your last message or start a new session for Claude Code to assist with a different task."
    ));
    assert!(is_refusal_error(
        "API Error: Claude can't help with this. Start a new session. Learn more: https://www.anthropic.com/legal/aup"
    ));
    assert!(!is_refusal_error(
        "Claude AI usage limit reached|1759600000"
    ));
    assert!(!is_refusal_error(
        "agent process closed (claude-sr): proxy down"
    ));
    assert!(!is_refusal_error("API Error: 529 overloaded"));
}

#[test]
fn a_refused_node_is_built_by_the_fallback_compactor() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: built by the fallback")));
    agents.inner.lock().unwrap().answer_error = Some(REFUSAL.into());
    let slots = Slots::new(COMPACTOR_SESSIONS);
    let main = Arc::new(AcpmuxCompactor::new(
        agents.clone(),
        spec(dir.path()),
        slots.clone(),
    ));
    let fallback = Arc::new(AcpmuxCompactor::new(
        agents.clone(),
        CompactorSpec {
            model: Some("claude-sonnet-5".into()),
            ..spec(dir.path())
        },
        slots,
    ));
    let chat = OptChat::open_with_fallback(
        dir.path().join("chat"),
        Config {
            reporter: Arc::new(|_| {}),
            ..Config::default()
        },
        main,
        Some(fallback),
        Arc::new(SystemClock),
    )
    .unwrap();
    chat.append(Kind::User, &"a long message; ".repeat(60))
        .unwrap();
    assert!(
        chat.settle(None, Some(WAIT)),
        "{:?}",
        chat.status().failures
    );
    assert!(
        chat.render_view()
            .text
            .contains("user: built by the fallback")
    );
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.specs[1].model.as_deref(), Some("claude-sonnet-5"));
}

// Audit round 3, m4: the start-up probe checks the fallback model too.
#[test]
fn the_probe_checks_the_fallback_model_too() {
    let dir = tempfile::tempdir().unwrap();
    let good = FakeAgents::new(Box::new(|_, _| answer("user: ping")));
    let bad = FakeAgents::new(Box::new(|_, _| answer("")));
    bad.inner.lock().unwrap().answer_error = Some("model claude-sonnet-5 not found".into());
    let main = compactor(&good, dir.path());
    let fallback = compactor(&bad, dir.path());
    assert_eq!(probe_models(&main, None, "SYS"), Ok("user: ping".into()));
    let error = probe_models(&main, Some(&fallback as &dyn CompactModel), "SYS").unwrap_err();
    assert!(error.contains("fallback"), "{error}");
    assert!(error.contains("not found"), "{error}");
}

/// A Claude Code `system/init` as acpmux records it.
fn init(tools: Value, mcp: Value) -> Value {
    update(
        "session_info_update",
        json!({"title": null, "_meta": {"claude": {"tools": tools, "mcp_servers": mcp, "model": "claude-sonnet-5-5"}}}),
    )
}

// Audit round 3, M3 and m4: the probe fails when the compactor session
// offers a tool or an MCP server.
#[test]
fn the_probe_fails_when_the_compactor_session_has_tools_or_mcp_servers() {
    let dir = tempfile::tempdir().unwrap();
    let with = |tools: Value, mcp: Value| {
        let agents = FakeAgents::new(Box::new(move |_, _| {
            let mut events = vec![init(tools.clone(), mcp.clone())];
            events.extend(answer("user: ping"));
            events
        }));
        probe(&compactor(&agents, dir.path()), "SYS")
    };
    assert_eq!(with(json!([]), json!([])), Ok("user: ping".into()));
    let error = with(json!(["AskUserQuestion", "Read"]), json!([])).unwrap_err();
    assert!(error.message.contains("AskUserQuestion"), "{error:?}");
    let error = with(
        json!([]),
        json!([{"name": "github", "status": "connected"}]),
    )
    .unwrap_err();
    assert!(error.message.contains("github"), "{error:?}");
}

// Audit round 3, M5: one host.log line per node with its token use.
#[test]
fn each_node_logs_its_seconds_and_token_use() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: hi")));
    agents.inner.lock().unwrap().answer = Some(json!({
        "stopReason": "end_turn",
        "_meta": {"claude": {"subtype": "success", "cost_usd": 0.081, "num_turns": 1, "usage": {
            "input_tokens": 3, "cache_creation_input_tokens": 21000,
            "cache_read_input_tokens": 9000, "output_tokens": 40
        }}}
    }));
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    let compactor = compactor(&agents, dir.path()).with_log(Arc::new(move |l: &str| {
        sink.lock().unwrap().push(l.to_owned())
    }));
    run_node(&compactor, &request(4)).unwrap();
    let lines = lines.lock().unwrap();
    let line = lines
        .iter()
        .find(|l| l.contains("4+1"))
        .expect("a node line");
    for part in [
        "uncached 3",
        "cache write 21000",
        "cache read 9000",
        "output 40",
        "$0.081",
    ] {
        assert!(line.contains(part), "{part} in {line}");
    }
}

// Audit round 3, m3: the main and fallback compactors share one gate.
#[test]
fn main_and_fallback_compactors_share_jobs_slots() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|turn, _| answer(&format!("user: node {turn}"))));
    agents.hold(true);
    let slots = Slots::new(COMPACTOR_SESSIONS);
    let a = Arc::new(AcpmuxCompactor::new(
        agents.clone(),
        spec(dir.path()),
        slots.clone(),
    ));
    let b = Arc::new(AcpmuxCompactor::new(
        agents.clone(),
        spec(dir.path()),
        slots,
    ));
    let workers: Vec<_> = (0..(COMPACTOR_SESSIONS + 4) as u64)
        .map(|i| {
            let c = if i % 2 == 0 { a.clone() } else { b.clone() };
            std::thread::spawn(move || run_node(&*c, &request(i)))
        })
        .collect();
    agents.wait_prompts(COMPACTOR_SESSIONS);
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(agents.inner.lock().unwrap().specs.len(), COMPACTOR_SESSIONS);
    let cwds: std::collections::BTreeSet<_> = agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .map(|s| s.cwd.clone())
        .collect();
    assert_eq!(
        cwds.len(),
        COMPACTOR_SESSIONS,
        "each live session has its own slot directory"
    );
    agents.hold(false);
    agents.release();
    for w in workers {
        assert!(w.join().unwrap().is_ok());
    }
}

// Audit round 3, M6: the node's Claude Code transcript is deleted with it.
#[test]
fn a_finished_node_deletes_its_claude_code_transcript() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_owned();
    let made = Arc::new(Mutex::new(None));
    let seen = made.clone();
    let agents = FakeAgents::new(Box::new(move |_, _| {
        // Claude Code writes the transcript under the config's projects/.
        let cwd = std::fs::canonicalize(root.join("work").join("slot-0")).unwrap();
        let project = root
            .join("compactor-claude")
            .join("projects")
            .join(project_dir_name(&cwd));
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(project.join("abc.jsonl"), "{}\n").unwrap();
        *seen.lock().unwrap() = Some(project);
        answer("user: hi")
    }));
    run_node(&compactor(&agents, dir.path()), &request(0)).unwrap();
    let project = made.lock().unwrap().clone().unwrap();
    assert!(!project.exists(), "{} is left", project.display());
}

// Live check 2026-10-04: `sr claude proxy` resets CLAUDE_CONFIG_DIR to
// ~/.claude, so the transcript lands there and the compactor config's user
// settings are never read; only the cwd's project settings are.
#[test]
fn the_transcript_is_deleted_from_the_users_claude_home_too() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_owned();
    let made = Arc::new(Mutex::new(None));
    let seen = made.clone();
    let agents = FakeAgents::new(Box::new(move |_, _| {
        let cwd = std::fs::canonicalize(root.join("work").join("slot-0")).unwrap();
        let project = root
            .join("user-claude")
            .join("projects")
            .join(project_dir_name(&cwd));
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(project.join("abc.jsonl"), "{}\n").unwrap();
        *seen.lock().unwrap() = Some(project);
        answer("user: hi")
    }));
    run_node(&compactor(&agents, dir.path()), &request(0)).unwrap();
    let project = made.lock().unwrap().clone().unwrap();
    assert!(!project.exists(), "{} is left", project.display());
}

#[test]
fn each_slot_directory_carries_the_deny_settings_as_project_settings() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: hi")));
    run_node(&compactor(&agents, dir.path()), &request(0)).unwrap();
    let cwd = agents.inner.lock().unwrap().specs[0].cwd.clone();
    let settings: Value =
        serde_json::from_slice(&std::fs::read(cwd.join(".claude").join("settings.json")).unwrap())
            .unwrap();
    assert_eq!(settings, compactor_settings());
    assert_eq!(settings["disableAllHooks"], true);
}

#[test]
fn project_dir_names_follow_claude_code() {
    assert_eq!(
        project_dir_name(std::path::Path::new(
            "/private/var/folders/x_y/T/optchat-compact-1a/slot-0"
        )),
        "-private-var-folders-x-y-T-optchat-compact-1a-slot-0"
    );
}

// Audit round 3, m5: Claude Code or the model may put a lead-in before the line.
#[test]
fn a_lead_in_before_the_line_is_dropped() {
    assert_eq!(
        strip_preamble("Here is the line:\nuser: asked X"),
        "user: asked X"
    );
    assert_eq!(
        strip_preamble("Here's the compressed line:\n\nuser: asked X"),
        "user: asked X"
    );
    assert_eq!(strip_preamble("user: asked X"), "user: asked X");
    assert_eq!(strip_preamble("user: a: b\nc"), "user: a: b\nc");
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("Here is the line:\nuser: ping")));
    assert_eq!(
        probe(&compactor(&agents, dir.path()), "SYS").unwrap(),
        "user: ping"
    );
}

// Audit round 3, M1, M3, M6 and m5: the compactor's own configuration.
#[test]
fn the_compactor_has_its_own_isolated_configuration() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = Paths::new(&home);
    let presets = compactor_presets(&paths, &home, "claude-sr", Family::Claude);
    let preset = &presets[0];
    assert!(
        preset.name.starts_with("optchat-compact-"),
        "{}",
        preset.name
    );
    assert!(
        preset
            .name
            .ends_with(&format!("{}-slot-0", optchat_chief::paths::home_id(&home)))
    );
    // cx-1hpt: no configuration directory of its own. A plain `claude`
    // compactor signs in with the user's login, which lives with the user's
    // Claude home (an empty `CLAUDE_CONFIG_DIR` has none: "Could not resolve
    // authentication method"). The slot's project settings, the env below
    // and the preset's flags keep it isolated.
    assert!(
        !preset.env.contains_key("CLAUDE_CONFIG_DIR"),
        "{:?}",
        preset.env
    );
    assert_eq!(preset.env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"], "1");
    assert_eq!(preset.env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "1");
    // Every slot on one sticky subrouter account (nodes share cached context).
    assert_eq!(
        preset.env["SUBROUTER_SESSION_KEY"],
        format!("optchat-{}-compact", optchat_chief::paths::home_id(&home))
    );
    let settings = compactor_settings();
    let deny: Vec<&str> = settings["permissions"]["deny"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    for tool in [
        "AskUserQuestion",
        "EnterPlanMode",
        "ExitPlanMode",
        "Bash",
        "Read",
        "Task",
    ] {
        assert!(deny.contains(&tool), "{tool} denied");
        assert!(DENIED_TOOLS.contains(&tool));
    }
    assert_eq!(settings["cleanupPeriodDays"], 1);
    assert_eq!(settings["autoMemoryEnabled"], false);
    let spec = compactor_spec(
        &paths,
        &home,
        "claude-sr",
        Family::Claude,
        Some("claude-sonnet-5-5"),
    );
    assert_eq!(spec.effort.as_deref(), Some("high"));
    assert_eq!(slot_preset(&spec.preset, 0), preset.name);
    assert!(spec.transcript_dirs.contains(&paths.compactor_config));
    assert!(
        spec.transcript_dirs.len() >= 2,
        "the user's Claude home too: sr resets CLAUDE_CONFIG_DIR"
    );
    assert!(
        !spec.work.starts_with(&home),
        "the compactor's cwd is outside the home: {}",
        spec.work.display()
    );
}

/// A `<chat>` context of `lines` 100-byte lines (about `lines * 100` characters).
fn chat_of(lines: usize) -> String {
    let line = format!("{}\n", "x".repeat(99));
    let mut context = String::from("<chat>\n");
    for _ in 0..lines {
        context.push_str(&line);
    }
    context.push_str("</chat>");
    context
}

fn markers(blocks: &[Value]) -> Vec<usize> {
    blocks
        .iter()
        .enumerate()
        .filter(|(_, b)| b.get("cache_control").is_some())
        .map(|(i, _)| i)
        .collect()
}

// Spec 3.3 and 4 (gist 3c190e0): a compaction is a call like a turn: the
// slot preset's system prompt is the system text alone (the turns' own), the
// view follows in blocks of 4 lines with ONE marker on the last whole block,
// then the task.
#[test]
fn with_system_prompt_support_the_system_text_is_the_slot_presets_prompt_and_one_marker_sits_on_the_last_whole_block()
 {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: a line")));
    agents.inner.lock().unwrap().system_prompts = true;
    let compactor = compactor(&agents, dir.path());
    let context = chat_of(150);
    let pieces = optchat_core::block_pieces(&context);
    let r = CompactRequest {
        context: context.clone(),
        ..request(0)
    };
    assert_eq!(run_node(&compactor, &r).unwrap(), "user: a line");
    let inner = agents.inner.lock().unwrap();
    let system = inner.systems[0]
        .clone()
        .expect("the slot preset's system prompt is set before the session");
    assert_eq!(system, "SYS");
    assert_eq!(
        inner.specs[0].preset.as_deref(),
        Some("optchat-compact-test-preset-slot-0")
    );
    let blocks = &inner.prompts[0];
    let t = texts(blocks);
    assert_eq!(t.len(), pieces.len() + 1);
    assert_eq!(t[..pieces.len()].concat(), context);
    assert_eq!(t.last().unwrap(), "STEP 0");
    let last_whole = pieces.len() - 2;
    assert_eq!(markers(blocks), vec![last_whole]);
    assert_eq!(t[last_whole].lines().count(), optchat_core::BLOCK_LINES);
    assert_eq!(
        inner.prompt_sets.last(),
        Some(&(
            "optchat-compact-test-preset-slot-0".to_owned(),
            String::new()
        ))
    );
    assert!(!inner.specs[0].cwd.join("system.md").exists());
}

#[test]
fn the_marker_sits_on_the_last_whole_four_line_block() {
    // 9 lines: two whole blocks, the marker on the second.
    let r = CompactRequest {
        context: chat_of(9),
        ..request(0)
    };
    let p = cached_prompt(&r, true);
    assert_eq!(markers(&p.blocks), vec![1]);
    assert_eq!(texts(&p.blocks).len(), 4);
    // Fewer than 4 lines: no whole block, no marker.
    let p = cached_prompt(&request(0), true);
    assert_eq!(p.system, "SYS");
    assert!(markers(&p.blocks).is_empty());
    assert_eq!(
        texts(&p.blocks),
        vec!["<chat>\nuser: hi\n</chat>", "STEP 0"]
    );
    // Without the marker the blocks are the same text.
    let r = CompactRequest {
        context: chat_of(1_100),
        ..request(0)
    };
    let (with, without) = (cached_prompt(&r, true), cached_prompt(&r, false));
    assert_eq!(texts(&with.blocks), texts(&without.blocks));
    assert!(markers(&without.blocks).is_empty());
}

#[test]
fn too_many_cache_breakpoints_retry_once_without_the_marker_and_say_so() {
    assert!(is_marker_limit_error(MARKER_LIMIT));
    assert!(!is_marker_limit_error("API Error: 529 overloaded"));
    assert!(!is_marker_limit_error(REFUSAL));
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: a line")));
    {
        let mut inner = agents.inner.lock().unwrap();
        inner.system_prompts = true;
        inner.answer_error = Some(MARKER_LIMIT.into());
    }
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    let compactor = compactor(&agents, dir.path()).with_log(Arc::new(move |l: &str| {
        sink.lock().unwrap().push(l.to_owned())
    }));
    let r = CompactRequest {
        context: chat_of(1_100),
        ..request(0)
    };
    // One call: the refused prompt, then a fresh session without the marker.
    assert_eq!(compactor.call(&r, &[]).unwrap().text, "user: a line");
    {
        let inner = agents.inner.lock().unwrap();
        assert_eq!(inner.prompts.len(), 2);
        let last_whole = optchat_core::block_pieces(&chat_of(1_100)).len() - 2;
        assert_eq!(markers(&inner.prompts[0]), vec![last_whole]);
        assert!(markers(&inner.prompts[1]).is_empty());
        assert_eq!(texts(&inner.prompts[0]), texts(&inner.prompts[1]));
        assert_eq!(inner.ended, vec!["s1"], "the refused session is gone");
        assert_eq!(inner.systems[1], inner.systems[0], "same system prompt");
    }
    compactor.end(&r);
    assert!(
        lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.contains("cache_control") && l.contains("without")),
        "{:?}",
        lines.lock().unwrap()
    );
    // Later nodes skip the marker instead of failing first.
    assert_eq!(run_node(&compactor, &request(1)).unwrap(), "user: a line");
    let r2 = CompactRequest {
        context: chat_of(1_100),
        ..request(2)
    };
    assert_eq!(run_node(&compactor, &r2).unwrap(), "user: a line");
    let inner = agents.inner.lock().unwrap();
    assert!(markers(inner.prompts.last().unwrap()).is_empty());
    assert_eq!(inner.prompts.len(), 4);
}

#[test]
fn without_system_prompt_support_the_old_layout_stays() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: a line")));
    let compactor = compactor(&agents, dir.path());
    let r = CompactRequest {
        context: chat_of(1_100),
        ..request(0)
    };
    run_node(&compactor, &r).unwrap();
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.systems[0], None, "no system prompt");
    assert!(inner.prompt_sets.is_empty());
    assert_eq!(inner.prompts[0], request_blocks(&r));
    assert!(markers(&inner.prompts[0]).is_empty());
}

#[test]
fn the_compactor_presets_are_one_per_slot_with_allowlisted_args_and_a_system_prompt() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = Paths::new(&home);
    let presets = compactor_presets(&paths, &home, "claude-sr", Family::Claude);
    assert_eq!(
        presets.len(),
        COMPACTOR_SESSIONS,
        "one per slot: a slot's prompt never races another's"
    );
    let id = optchat_chief::paths::home_id(&home);
    for (k, p) in presets.iter().enumerate() {
        assert_eq!(p.name, format!("optchat-compact-{id}-slot-{k}"));
        // acpmux's allowlist: no tools, no MCP servers, no transcript, no
        // user settings, no skills; the system prompt is the preset's text,
        // never a path in the cwd.
        assert_eq!(
            p.args,
            vec![
                "--tools",
                "",
                "--strict-mcp-config",
                "--no-session-persistence",
                "--setting-sources",
                "project",
                "--disable-slash-commands"
            ]
        );
        assert!(p.system_prompt.is_some(), "installed with a system prompt");
    }
    assert_eq!(presets[0].args, COMPACTOR_ARGS);
    // Claude Code flags and system prompts mean nothing to another harness.
    let codex = compactor_presets(&paths, &home, "codex", Family::Codex);
    assert_eq!(codex.len(), COMPACTOR_SESSIONS);
    assert!(
        codex
            .iter()
            .all(|p| p.args.is_empty() && p.system_prompt.is_none())
    );
}

/// Codex caches a byte-identical request prefix automatically: every node
/// runs in ONE working directory (its environment context names the cwd),
/// with the old layout (system text first, no marker, no system prompt).
#[test]
fn a_codex_compactor_shares_one_working_directory_and_keeps_a_byte_stable_prefix() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: a line")));
    agents.inner.lock().unwrap().system_prompts = true;
    let spec = CompactorSpec {
        harness: "codex".into(),
        family: Family::Codex,
        model: None,
        ..spec(dir.path())
    };
    // Two nodes at once, so they hold two slots.
    let compactor = Arc::new(AcpmuxCompactor::new(
        agents.clone(),
        spec,
        Slots::new(COMPACTOR_SESSIONS),
    ));
    agents.hold(true);
    let r = |i: u64| CompactRequest {
        context: chat_of(1_100),
        ..request(i)
    };
    let threads: Vec<_> = (0..2)
        .map(|i| {
            let c = compactor.clone();
            let req = r(i);
            std::thread::spawn(move || run_node(&*c, &req).unwrap())
        })
        .collect();
    agents.wait_prompts(2);
    agents.release();
    agents.release();
    for t in threads {
        t.join().unwrap();
    }
    let inner = agents.inner.lock().unwrap();
    let work = std::fs::canonicalize(dir.path().join("work")).unwrap();
    assert_eq!(inner.specs[0].cwd, work.join("shared"));
    assert_eq!(inner.specs[1].cwd, work.join("shared"));
    assert_ne!(inner.specs[0].preset, inner.specs[1].preset, "two slots");
    assert!(inner.prompt_sets.is_empty(), "no system prompt on codex");
    assert_eq!(inner.specs[0].model, None, "the harness's own model");
    for (i, blocks) in inner.prompts.iter().enumerate() {
        assert!(markers(blocks).is_empty());
        let node = if texts(blocks).last().unwrap().ends_with('0') {
            0
        } else {
            1
        };
        assert_eq!(*blocks, request_blocks(&r(node)), "prompt {i}");
    }
}

#[test]
fn a_codex_node_logs_its_cached_tokens() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: hi")));
    agents.inner.lock().unwrap().answer = Some(json!({
        "stopReason": "end_turn",
        "usage": {"totalTokens": 31000, "inputTokens": 900, "cachedReadTokens": 30000, "outputTokens": 100, "thoughtTokens": 60}
    }));
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    let spec = CompactorSpec {
        harness: "codex".into(),
        family: Family::Codex,
        model: None,
        ..spec(dir.path())
    };
    let compactor = AcpmuxCompactor::new(agents.clone(), spec, Slots::new(COMPACTOR_SESSIONS))
        .with_log(Arc::new(move |l: &str| {
            sink.lock().unwrap().push(l.to_owned())
        }));
    run_node(&compactor, &request(4)).unwrap();
    let lines = lines.lock().unwrap();
    let line = lines
        .iter()
        .find(|l| l.contains("4+1"))
        .expect("a node line");
    for part in [
        "uncached 900",
        "cache write 0",
        "cache read 30000",
        "output 100",
        "codex",
    ] {
        assert!(line.contains(part), "{part} in {line}");
    }
}

/// Codex compactor slots: each preset points `CODEX_HOME` at its slot's own
/// home and carries the Chief's compactor cache key; no Claude Code env,
/// args or system prompt.
#[test]
fn codex_compactor_presets_give_each_slot_its_own_codex_home_and_the_compact_cache_key() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = Paths::new(&home);
    let id = optchat_chief::paths::home_id(&home);
    let presets = compactor_presets(&paths, &home, "codex", Family::Codex);
    assert_eq!(presets.len(), COMPACTOR_SESSIONS);
    let mut homes = std::collections::BTreeSet::new();
    for (k, p) in presets.iter().enumerate() {
        assert_eq!(p.name, format!("optchat-compact-{id}-slot-{k}"));
        assert_eq!(
            p.env["CODEX_HOME"],
            paths
                .compactor_codex
                .join(format!("slot-{k}"))
                .display()
                .to_string()
        );
        assert_eq!(
            p.env["CODEX_PROMPT_CACHE_KEY"],
            format!("optchat-{id}-compact")
        );
        assert!(!p.env.contains_key("CLAUDE_CONFIG_DIR"));
        assert!(p.args.is_empty() && p.system_prompt.is_none());
        homes.insert(p.env["CODEX_HOME"].clone());
    }
    assert_eq!(homes.len(), COMPACTOR_SESSIONS, "one CODEX_HOME per slot");
}

/// A slot's codex config.toml keeps where requests go and the model, and
/// nothing else of the user's (MCP servers, notify, projects, hooks,
/// profiles); it turns off project AGENTS.md, skills, apps, plugins,
/// memories and hooks.
#[test]
fn the_codex_compactor_config_keeps_routing_and_drops_everything_else() {
    use optchat_chief::compactor::{codex_compactor_config, prepare_codex_homes};
    let user = r#"
model = "gpt-6-astra"
openai_base_url = "http://router:31415/v1"
chatgpt_base_url = "http://router:31415/backend-api"
notify = ["/bin/notifier"]
approval_policy = "never"
developer_instructions = "be terse"

[mcp_servers.github]
command = "gh-mcp"

[projects."/"]
trust_level = "trusted"

[model_providers.sr]
name = "subrouter"
base_url = "http://router:31415/v1"
"#;
    let text = codex_compactor_config(Some(user)).unwrap();
    let config: toml::Table = text.parse().unwrap();
    assert_eq!(config["model"].as_str(), Some("gpt-6-astra"));
    assert_eq!(
        config["openai_base_url"].as_str(),
        Some("http://router:31415/v1")
    );
    assert_eq!(
        config["model_providers"]["sr"]["base_url"].as_str(),
        Some("http://router:31415/v1")
    );
    for gone in [
        "mcp_servers",
        "notify",
        "projects",
        "approval_policy",
        "developer_instructions",
    ] {
        assert!(!config.contains_key(gone), "{gone} in {text}");
    }
    assert_eq!(config["project_doc_max_bytes"].as_integer(), Some(0));
    assert_eq!(
        config["skills"]["include_instructions"].as_bool(),
        Some(false)
    );
    assert_eq!(
        config["skills"]["bundled"]["enabled"].as_bool(),
        Some(false)
    );
    for feature in [
        "apps",
        "plugins",
        "memories",
        "hooks",
        "multi_agent",
        "code_mode",
    ] {
        assert_eq!(
            config["features"][feature].as_bool(),
            Some(false),
            "{feature}"
        );
    }
    assert_eq!(
        config["features"]["skip_host_skill_discovery"].as_bool(),
        Some(true)
    );
    // Live 2026-10-04: `code_mode_host = false` makes codex-acp put "Code
    // Mode is unavailable because code-mode host is disabled" at the head of
    // every node's reply, so the slot leaves that key alone.
    assert!(
        !config["features"]
            .as_table()
            .unwrap()
            .contains_key("code_mode_host"),
        "{text}"
    );
    // codex reports an under-development feature as an error item each
    // session; the slot asks it not to.
    assert_eq!(
        config["suppress_unstable_features_warning"].as_bool(),
        Some(true)
    );
    // Without a user config: the isolation alone.
    let bare: toml::Table = codex_compactor_config(None).unwrap().parse().unwrap();
    assert!(!bare.contains_key("model"));

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(&dir.path().join("mux"));
    let user_home = dir.path().join("user-codex");
    std::fs::create_dir_all(user_home.join("skills/mine")).unwrap();
    std::fs::write(user_home.join("config.toml"), user).unwrap();
    std::fs::write(user_home.join("AGENTS.md"), "user instructions").unwrap();
    std::fs::write(user_home.join("auth.json"), "{}").unwrap();
    prepare_codex_homes(&paths, &user_home).unwrap();
    for k in 0..COMPACTOR_SESSIONS {
        let slot = paths.compactor_codex.join(format!("slot-{k}"));
        let mut names: Vec<String> = std::fs::read_dir(&slot)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        // Live 2026-10-04: codex-acp refuses session/new without a sign-in
        // ("Authentication required"), so the slot shares the user's
        // auth.json through a symlink: one credential, no copy whose token
        // refresh could invalidate the user's (codex writes it in place).
        assert_eq!(
            names,
            vec!["auth.json", "config.toml", "installation_id"],
            "slot {k}: its config, the user's sign-in and the Chief's installation id"
        );
        assert_eq!(
            std::fs::read_link(slot.join("auth.json")).unwrap(),
            user_home.join("auth.json")
        );
        assert_eq!(
            std::fs::read_to_string(slot.join("config.toml")).unwrap(),
            text
        );
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&slot).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
    }
    // Live 2026-10-04: the subrouter keeps a codex installation id on one
    // account, and the prompt cache is per account: two slots with their own
    // ids read 0 of a 31.5k-token prefix the other wrote, with one shared id
    // 30,464. Every slot carries the same id, a UUID codex accepts, and a
    // host restart keeps it.
    let ids: Vec<String> = (0..COMPACTOR_SESSIONS)
        .map(|k| {
            std::fs::read_to_string(
                paths
                    .compactor_codex
                    .join(format!("slot-{k}"))
                    .join("installation_id"),
            )
            .unwrap()
        })
        .collect();
    assert!(ids.iter().all(|id| *id == ids[0]), "{ids:?}");
    let id = &ids[0];
    assert_eq!(id.len(), 36, "{id}");
    assert_eq!(
        id.chars().filter(|c| *c == '-').count(),
        4,
        "a hyphenated UUID: {id}"
    );
    assert_eq!(&id[14..15], "4", "version 4: {id}");
    prepare_codex_homes(&paths, &user_home).unwrap();
    assert_eq!(
        std::fs::read_to_string(paths.compactor_codex.join("slot-3/installation_id")).unwrap(),
        *id,
        "stable across host starts"
    );
}

/// Everything codex writes into a slot's CODEX_HOME during a node (its
/// rollout, thread database, history) is gone when the node ends; so is a
/// crash's leftover before the next node starts. The config stays.
#[test]
fn a_codex_node_leaves_nothing_but_its_config_in_its_codex_home() {
    use optchat_chief::compactor::prepare_codex_homes;
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(&dir.path().join("mux"));
    let user_home = dir.path().join("user-codex");
    std::fs::create_dir_all(&user_home).unwrap();
    std::fs::write(user_home.join("auth.json"), "{}").unwrap();
    prepare_codex_homes(&paths, &user_home).unwrap();
    let base = paths.compactor_codex.clone();
    // A crash's leftover in every slot.
    for k in 0..COMPACTOR_SESSIONS {
        let slot = base.join(format!("slot-{k}"));
        std::fs::create_dir_all(slot.join("sessions/2026/10/04")).unwrap();
        std::fs::write(slot.join("sessions/2026/10/04/rollout-old.jsonl"), "old").unwrap();
    }
    let seen_leftover = Arc::new(Mutex::new(Vec::<bool>::new()));
    let seen = seen_leftover.clone();
    let writes = base.clone();
    // The fake harness writes as codex does, into every slot (it does not
    // know which one the node holds).
    let agents = FakeAgents::new(Box::new(move |_, _| {
        for k in 0..COMPACTOR_SESSIONS {
            let slot = writes.join(format!("slot-{k}"));
            seen.lock()
                .unwrap()
                .push(slot.join("sessions/2026/10/04/rollout-old.jsonl").exists());
            std::fs::create_dir_all(slot.join("sessions/2026/10/05")).unwrap();
            std::fs::write(slot.join("sessions/2026/10/05/rollout-new.jsonl"), "chat").unwrap();
            std::fs::write(slot.join("state_5.sqlite"), "threads").unwrap();
            std::fs::write(slot.join("history.jsonl"), "chat").unwrap();
            std::fs::write(slot.join("models_cache.json"), "{}").unwrap();
        }
        answer("user: a line")
    }));
    let spec = CompactorSpec {
        harness: "codex".into(),
        family: Family::Codex,
        codex_home: base.clone(),
        model: None,
        ..spec(dir.path())
    };
    let compactor = AcpmuxCompactor::new(agents.clone(), spec, Slots::new(COMPACTOR_SESSIONS));
    run_node(&compactor, &request(1)).unwrap();
    // The node held slot 0: its leftover was gone before the session started.
    assert!(!seen_leftover.lock().unwrap()[0]);
    let slot = base.join("slot-0");
    let mut names: Vec<String> = std::fs::read_dir(&slot)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(
        names,
        vec![
            "auth.json",
            "config.toml",
            "installation_id",
            "models_cache.json"
        ]
    );
    assert_eq!(
        std::fs::read_to_string(slot.join("auth.json")).unwrap(),
        "{}",
        "the user's sign-in survives the wipe"
    );
}

/// The probe fails when a codex compactor session offers a skill (codex-acp
/// lists each as a `$name` command): a chat line naming it would pull the
/// skill's text into the node.
#[test]
fn the_probe_fails_when_a_codex_session_offers_skills() {
    let dir = tempfile::tempdir().unwrap();
    let with = |commands: Value| {
        let agents = FakeAgents::new(Box::new(move |_, _| {
            let mut events = vec![update(
                "available_commands_update",
                json!({"availableCommands": commands.clone()}),
            )];
            events.extend(answer("user: ping"));
            events
        }));
        let spec = CompactorSpec {
            harness: "codex".into(),
            family: Family::Codex,
            model: None,
            ..spec(dir.path())
        };
        probe(
            &AcpmuxCompactor::new(agents, spec, Slots::new(COMPACTOR_SESSIONS)),
            "SYS",
        )
    };
    let builtin = json!([{"name": "compact", "description": "Summarize"}, {"name": "status"}]);
    assert_eq!(with(builtin), Ok("user: ping".into()));
    let error = with(json!([{"name": "status"}, {"name": "$cmux-browser"}, {"name": "$imagegen"}]))
        .unwrap_err();
    assert!(error.message.contains("$cmux-browser"), "{error:?}");
    assert!(error.message.contains("$imagegen"), "{error:?}");
}

/// hq-6d gap 3b: a Claude compactor runs Claude Haiku 5.5 at high effort,
/// as the reference client does (Haiku overshoots the size limit more often;
/// the ruler and the "Too long" retry handle it). acpmux maps `effort` onto
/// Claude Code's `--effort` and codex's `reasoning_effort` (codex keeps
/// medium: it is not Haiku); a harness of another family keeps its own.
#[test]
fn a_claude_compactor_runs_haiku_at_high_effort() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let paths = Paths::new(&home);
    for (harness, family, effort) in [
        ("claude-sr", Family::Claude, Some("high")),
        ("codex", Family::Codex, Some("medium")),
        ("opencode", Family::Other, None),
    ] {
        let spec = compactor_spec(&paths, &home, harness, family, None);
        assert_eq!(spec.effort.as_deref(), effort, "{harness}");
    }
    assert_eq!(Config::default().model, "claude-haiku-5-5");
    assert_eq!(Config::default().effort.as_deref(), Some("high"));
}

/// What Claude Code answers when the account cannot use the model.
const NO_MODEL: &str = "There's an issue with the selected model (claude-haiku-5-5). It may not exist or you may not have access to it. Run /model to pick a different model.";

/// hq-6d: when the subscription route has no Haiku, the compactor builds
/// with the turn model from then on, and says so once.
#[test]
fn a_compactor_without_its_model_falls_back_to_the_turn_model_once() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: pasted a deploy log")));
    agents.inner.lock().unwrap().answer_error = Some(NO_MODEL.into());
    let lines: Arc<Mutex<Vec<String>>> = Arc::default();
    let sink = lines.clone();
    let spec = CompactorSpec {
        model: Some("claude-haiku-5-5".into()),
        ..spec(dir.path())
    };
    let compactor = AcpmuxCompactor::new(agents.clone(), spec, Slots::new(COMPACTOR_SESSIONS))
        .with_model_fallback(Some("claude-opus-5-5".into()))
        .with_log(Arc::new(move |l: &str| {
            sink.lock().unwrap().push(l.to_owned())
        }));
    assert_eq!(
        run_node(&compactor, &request(1)).unwrap(),
        "user: pasted a deploy log"
    );
    assert_eq!(
        run_node(&compactor, &request(2)).unwrap(),
        "user: pasted a deploy log"
    );
    let models: Vec<Option<String>> = agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .map(|s| s.model.clone())
        .collect();
    assert_eq!(
        models,
        vec![
            Some("claude-haiku-5-5".to_owned()),
            Some("claude-opus-5-5".to_owned()),
            Some("claude-opus-5-5".to_owned()),
        ]
    );
    let said = lines
        .lock()
        .unwrap()
        .iter()
        .filter(|l| l.contains("is not available"))
        .count();
    assert_eq!(said, 1, "{:?}", lines.lock().unwrap());
}

/// Single-flight (hq-6d gap 3a): the next node with the same marked prefix
/// prompts as soon as the writing node's harness streams its first output
/// (its cache entry exists then), not when the writer's turn ends.
#[test]
fn the_next_node_prompts_at_the_writers_first_streamed_output() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: pasted a deploy log")));
    agents.hold(true);
    let config = Config {
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    let chat = OptChat::open_with(
        dir.path().join("chat"),
        config,
        Arc::new(compactor(&agents, dir.path())),
        Arc::new(SystemClock),
    )
    .unwrap();
    // Two long messages on an empty chat: both nodes mark the same prefix.
    chat.append(Kind::User, &"deploy step; ".repeat(100))
        .unwrap();
    chat.append(Kind::User, &"build step; ".repeat(100))
        .unwrap();
    agents.wait_prompts(1);
    // The writer's harness streams its first chunk: acpmux says Changed.
    let writer = agents
        .inner
        .lock()
        .unwrap()
        .signals
        .values()
        .next()
        .cloned()
        .unwrap();
    writer
        .send(optchat_chief::acpmux::TurnSignal::Changed)
        .unwrap();
    agents.wait_prompts(2);
    agents.release();
    agents.release();
    assert!(
        chat.settle(None, Some(WAIT)),
        "{:?}",
        chat.status().failures
    );
}

/// hq-6d gap 3b: a node does not wait for a Claude Code process to start.
/// When a node ends, a warm session starts in its slot with the same system
/// prompt, and the next node prompts it at once (a fresh conversation per
/// node, as the spec needs; a session is never reused across nodes).
#[test]
fn the_next_node_takes_a_warm_session_started_when_the_last_one_ended() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: pasted a deploy log")));
    agents.inner.lock().unwrap().system_prompts = true;
    let compactor = compactor(&agents, dir.path()).with_warm(2);
    for i in 1..=2 {
        assert_eq!(
            run_node(&compactor, &request(i)).unwrap(),
            "user: pasted a deploy log"
        );
    }
    let inner = agents.inner.lock().unwrap();
    let names: Vec<&str> = inner.specs.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(
        names,
        [
            "optchat-compact-test-1+1",
            "optchat-compact-test-warm-0",
            "optchat-compact-test-warm-0"
        ]
    );
    // Each warm session started with the nodes' system prompt.
    let system = cached_prompt(&request(1), true).system;
    for k in 1..=2 {
        assert_eq!(inner.systems[k].as_deref(), Some(system.as_str()));
    }
    // Node 2 prompted the first warm session and ended it; the second waits.
    assert_eq!(inner.prompts.len(), 2);
    assert_eq!(inner.ended, ["s1", "s2"]);
}

/// cx-1hpt: the compactor's failure notice is posted once, also across host
/// restarts (each start probes again), and a later good probe retracts it.
#[test]
fn the_compactor_notice_is_posted_once_across_restarts_and_retracted_when_it_works() {
    let text = "The memory compactor cannot build summaries (acpmux route: no login).";
    let down = || Input::CompactorStatus(Err(text.into()));
    let mut h = Harness::new(default_script());
    h.connect();
    h.brain.step(down());
    let Harness {
        dir,
        chat,
        owner,
        brain,
        ..
    } = h;
    drop(brain);
    chat.shutdown();
    drop(chat);
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.brain.step(down());
    let notices: Vec<(String, String)> = h
        .owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .filter(|(_, t)| t == text)
        .collect();
    assert_eq!(notices.len(), 1, "{notices:?}");
    h.brain.step(Input::CompactorStatus(Ok(())));
    let owner = h.owner.lock().unwrap();
    let posted = owner
        .messages
        .iter()
        .find(|m| matches!(&m.parts[0], cmux_conversation::Part::Text { text: t, .. } if t == text))
        .map(|m| m.id.clone())
        .unwrap();
    assert!(
        owner.ops.iter().any(|(_, op)| matches!(
            op,
            cmux_conversation::Op::MessageRetract { message_id } if *message_id == posted
        )),
        "{:?}",
        owner.ops
    );
}

/// Codex reads user skills from `$HOME/.agents/skills` whatever CODEX_HOME
/// and the slot config say (codex ext/skills host_roots.rs), so a slot on a
/// host with user skills offered them and the isolation check refused every
/// node (cmux-lawrence 2026-10-08: "it offers skills [$aside-browser, …]").
/// Each codex slot runs with HOME at a private empty directory.
#[test]
fn codex_compactor_sessions_run_with_a_private_home_without_user_skills() {
    use optchat_chief::compactor::prepare_codex_homes;
    use std::os::unix::fs::PermissionsExt;

    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = Paths::new(&home);
    let user_home = dir.path().join("user-codex");
    std::fs::create_dir_all(&user_home).unwrap();
    prepare_codex_homes(&paths, &user_home).unwrap();
    for p in compactor_presets(&paths, &home, "codex", Family::Codex) {
        let private = std::path::PathBuf::from(
            p.env
                .get("HOME")
                .unwrap_or_else(|| panic!("{} sets no HOME", p.name)),
        );
        assert!(
            private.starts_with(&paths.compactor_codex),
            "{}",
            private.display()
        );
        let meta = std::fs::metadata(&private).expect("the private home exists");
        assert!(meta.is_dir());
        assert_eq!(meta.permissions().mode() & 0o777, 0o700);
        assert!(
            !private.join(".agents").exists(),
            "no user skills under the private home"
        );
    }
    // Claude slots keep the user's HOME (their login lives there).
    for p in compactor_presets(&paths, &home, "claude-sr", Family::Claude) {
        assert!(!p.env.contains_key("HOME"), "{}", p.name);
    }
}

/// One TTL drives turns and compactions on a route (coordinator decision
/// 2026-10-08): each node takes the brain's current TTL for its mark, and
/// its slot's Claude Code settings pin Claude Code's own marks to it
/// (FORCE_PROMPT_CACHING_5M at 5 minutes, since a subscription login marks
/// 1 hour otherwise).
#[test]
fn each_node_takes_the_shared_cache_ttl_for_its_mark_and_its_slot_settings() {
    use optchat_chief::prompt::{CacheTtl, SharedTtl};
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: a line")));
    agents.inner.lock().unwrap().system_prompts = true;
    let ttl = SharedTtl::new(CacheTtl::FiveMinutes);
    let compactor = compactor(&agents, dir.path()).with_cache_ttl(ttl.clone());
    let slot_settings = |agents: &FakeAgents, k: usize| -> Value {
        let cwd = agents.inner.lock().unwrap().specs[k].cwd.clone();
        serde_json::from_slice(&std::fs::read(cwd.join(".claude").join("settings.json")).unwrap())
            .unwrap()
    };
    let mark = |agents: &FakeAgents, k: usize| -> Value {
        let inner = agents.inner.lock().unwrap();
        let blocks = &inner.prompts[k];
        blocks[markers(blocks)[0]]["cache_control"].clone()
    };
    let r = |i| CompactRequest {
        context: chat_of(150),
        ..request(i)
    };
    run_node(&compactor, &r(0)).unwrap();
    assert_eq!(mark(&agents, 0), json!({"type": "ephemeral"}));
    let s = slot_settings(&agents, 0);
    assert_eq!(s["promptCacheTtl"], "5m");
    assert_eq!(s["env"]["FORCE_PROMPT_CACHING_5M"], "1");
    ttl.set(CacheTtl::OneHour);
    run_node(&compactor, &r(1)).unwrap();
    assert_eq!(mark(&agents, 1), json!({"type": "ephemeral", "ttl": "1h"}));
    let s = slot_settings(&agents, 1);
    assert_eq!(s["promptCacheTtl"], "1h");
    assert!(s["env"].get("FORCE_PROMPT_CACHING_5M").is_none(), "{s}");
}

#[test]
fn compactor_presets_force_no_ttl_the_slot_settings_pick_it() {
    let dir = tempfile::tempdir().unwrap();
    let paths = optchat_chief::paths::Paths::new(dir.path());
    for preset in compactor_presets(&paths, dir.path(), "claude", Family::Claude) {
        assert!(
            !preset.env.contains_key("FORCE_PROMPT_CACHING_5M"),
            "{}: a preset is installed once; the TTL can change per node",
            preset.name
        );
    }
}

/// A refused mark (Claude Code already used the API's four) is not refused
/// for good: after 10 nodes without it the compactor tries it again.
#[test]
fn a_refused_marker_comes_back_after_ten_nodes() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: a line")));
    {
        let mut inner = agents.inner.lock().unwrap();
        inner.system_prompts = true;
        inner.answer_error = Some(MARKER_LIMIT.into());
    }
    let compactor = compactor(&agents, dir.path());
    let r = |i| CompactRequest {
        context: chat_of(150),
        ..request(i)
    };
    // Node 0: refused, then again without the marker.
    assert_eq!(run_node(&compactor, &r(0)).unwrap(), "user: a line");
    for i in 1..=10 {
        assert_eq!(run_node(&compactor, &r(i)).unwrap(), "user: a line");
    }
    assert_eq!(run_node(&compactor, &r(11)).unwrap(), "user: a line");
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.prompts.len(), 13);
    for k in 1..=11 {
        assert!(markers(&inner.prompts[k]).is_empty(), "prompt {k}");
    }
    assert_eq!(
        markers(&inner.prompts[12]).len(),
        1,
        "the 12th node tries the mark again"
    );
}

/// Claude Code without the model in its own table answers a failed call
/// with "[claude-code:unrecognized_model]" (2.1.287 on claude-haiku-5-5):
/// the compactor falls back to the turn model then too.
#[test]
fn an_unrecognized_model_counts_as_unavailable() {
    assert!(optchat_chief::compactor::is_model_unavailable(
        r#"[claude-code:unrecognized_model] {"model":"claude-haiku-5-5","query_source":"sdk"}"#
    ));
    assert!(!optchat_chief::compactor::is_model_unavailable(
        "API Error: 529 overloaded"
    ));
}

/// An acpmux older than the isolation args refuses them: the preset is
/// installed with the args it knows (`--tools ""` and the rest) kept.
#[test]
fn an_older_acpmux_keeps_the_args_it_knows() {
    use optchat_chief::acpmux::without_isolation_args;
    let args: Vec<Value> = optchat_chief::compactor::COMPACTOR_ARGS
        .iter()
        .map(|a| json!(a))
        .collect();
    assert_eq!(
        without_isolation_args(&args).unwrap(),
        vec![
            json!("--tools"),
            json!(""),
            json!("--strict-mcp-config"),
            json!("--no-session-persistence")
        ]
    );
    assert_eq!(without_isolation_args(&[json!("--tools"), json!("")]), None);
    // A turn's built-in list goes too (its denied tools still apply).
    let turn: Vec<Value> = optchat_chief::host::turn_isolation_args()
        .into_iter()
        .map(Value::String)
        .collect();
    assert_eq!(without_isolation_args(&turn), Some(Vec::new()));
    // An acpmux that knows the setting source but not a --tools list loses
    // only the list: the turn keeps its setting-source isolation.
    use optchat_chief::acpmux::without_tools_list;
    assert_eq!(
        without_tools_list(&turn),
        Some(vec![
            json!("--setting-sources"),
            json!("project"),
            json!("--disable-slash-commands")
        ])
    );
    assert_eq!(without_tools_list(&args), None, "--tools \"\" stays");
}

/// A compactor slot loads no user setting source, so its project settings
/// carry the env of the user's Claude Code settings (the user's API route).
#[test]
fn a_compactor_slot_carries_the_users_settings_env() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: pasted a deploy log")));
    let spec = CompactorSpec {
        user_env: [(
            "ANTHROPIC_BASE_URL".to_owned(),
            "http://router:31415".to_owned(),
        )]
        .into(),
        ..spec(dir.path())
    };
    let compactor = AcpmuxCompactor::new(agents.clone(), spec, Slots::new(COMPACTOR_SESSIONS));
    run_node(&compactor, &request(1)).unwrap();
    let work = std::fs::canonicalize(dir.path().join("work")).unwrap();
    let settings: Value = serde_json::from_slice(
        &std::fs::read(work.join("slot-0").join(".claude").join("settings.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "http://router:31415");
}

/// Claude Code 2.1.287 does not know `claude-haiku-5-5`
/// ("[claude-code:unrecognized_model]") but takes the `haiku` alias, which
/// it maps to its current Haiku. A Claude Code compactor asks for the
/// alias; the Messages API route keeps the full id; another harness keeps
/// its own default.
#[test]
fn the_compactor_model_resolves_per_harness() {
    use optchat_chief::compactor::compactor_model_for;
    assert_eq!(compactor_model_for(Family::Claude).as_deref(), Some("haiku"));
    assert_eq!(compactor_model_for(Family::Codex), None);
    assert_eq!(compactor_model_for(Family::Other), None);
    assert_eq!(Config::default().model, "claude-haiku-5-5");
}

/// The slot settings may hold the user's settings env (an API token among
/// it): the file is the user's alone (0600).
#[test]
fn a_compactor_slots_settings_file_is_private() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: pasted a deploy log")));
    let spec = CompactorSpec {
        user_env: [("ANTHROPIC_AUTH_TOKEN".to_owned(), "t".to_owned())].into(),
        ..spec(dir.path())
    };
    let compactor = AcpmuxCompactor::new(agents.clone(), spec, Slots::new(COMPACTOR_SESSIONS));
    run_node(&compactor, &request(1)).unwrap();
    let work = std::fs::canonicalize(dir.path().join("work")).unwrap();
    let file = work.join("slot-0").join(".claude").join("settings.json");
    let mode = std::fs::metadata(&file).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "{mode:o}");
}
