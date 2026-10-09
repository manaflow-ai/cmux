//! The Chief on local ACP with the harness as a setting (README, Harnesses
//! and cache layout), against the fake acpmux port:
//!
//! - Claude harnesses: each turn sets the turn preset's system prompt to the
//!   system text plus the view up to its first cache mark (acpmux writes it
//!   into its own preset directory), and the prompt carries the rest of the
//!   view with ONE `cache_control` marker at the last mark, then the new
//!   messages; the session directory then holds no CLAUDE.md (the system
//!   prompt carries it). A 4-breakpoint refusal reruns the turn without the
//!   marker. An acpmux without `systemPrompt` keeps the old layout.
//! - Any other harness (codex): no system prompt and no marker; the view
//!   first and the new messages last, byte-stable for automatic prefix
//!   caching, instructions in the session directory's AGENTS.md with the
//!   memory tools as `chief zoom` / `chief date` commands.
//! - Usage lines for both answer shapes; the harness switch.

mod common;

use std::sync::{Arc, Mutex};

use common::*;
use optchat_chief::brain::Settings;
use optchat_chief::fold::{Usage, answer_usage};
use optchat_chief::prompt::{
    CacheTtl, Mark, Tools, cached_layout_marked, claude_md, system_text, turn_blocks,
};
use optchat_core::Kind;
use serde_json::{Value, json};

/// About `n` 110-byte notes, each its own verbatim view line.
fn fill(chat: &optchat_host::OptChat, n: usize) {
    for i in 0..n {
        chat.append(
            Kind::Note,
            &format!(
                "note {i:04}: the build cache for project {i} lives in /srv/cache/{i} on host b{i}"
            ),
        )
        .unwrap();
    }
    assert!(chat.wait_idle(None, Some(WAIT)));
}

fn texts(blocks: &[Value]) -> Vec<String> {
    blocks
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default().to_owned())
        .collect()
}

fn markers(blocks: &[Value]) -> Vec<usize> {
    blocks
        .iter()
        .enumerate()
        .filter(|(_, b)| b.get("cache_control").is_some())
        .map(|(i, _)| i)
        .collect()
}

fn owner() -> Arc<Mutex<Owner>> {
    Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }))
}

fn harness_with(settings: impl FnOnce(&std::path::Path) -> Settings) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let s = settings(dir.path());
    Harness::configured(dir, default_script(), owner(), s, Arc::new(|_: &str| {}))
}

/// Spec 3.3 (gist 3c190e0): the view goes in blocks of 4 lines, one marker
/// on the last whole block; the system prompt is the constant text alone, so
/// turns and compactions send the same one.
#[test]
fn a_claude_turn_marks_the_last_whole_four_line_block_of_the_view() {
    let mut h = harness_with(settings);
    h.agents.inner.lock().unwrap().system_prompts = true;
    fill(&h.chat, 1_200);
    let view = h.chat.render_view().text;
    let pieces = optchat_core::block_pieces(&view);
    h.connect();
    h.say("user_local", "where is project 7?");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs[0].preset.as_deref(), Some(TURN_PRESET));
    assert_eq!(
        inner.prompt_sets,
        vec![(TURN_PRESET.to_owned(), claude_md(None))]
    );
    assert_eq!(inner.systems[0].as_deref(), Some(claude_md(None).as_str()));
    let blocks = &inner.prompts[0];
    let t = texts(blocks);
    assert_eq!(t[..t.len() - 1].concat(), view);
    assert_eq!(t.len(), pieces.len() + 1);
    assert_eq!(t.last().unwrap(), "where is project 7?");
    // The last whole block: the piece before the incomplete one.
    assert_eq!(markers(blocks), vec![t.len() - 3]);
    let marked = &t[t.len() - 3];
    assert_eq!(marked.lines().count(), optchat_core::BLOCK_LINES);
    // A 1-hour mark on the Claude Code path (tests/turn_cache.rs).
    assert_eq!(
        blocks[t.len() - 3]["cache_control"],
        json!({"type": "ephemeral", "ttl": "1h"})
    );
    assert_eq!(
        *blocks,
        cached_layout_marked(
            &claude_md(None),
            &view,
            "where is project 7?",
            Some(Mark {
                piece: t.len() - 3,
                ttl: CacheTtl::OneHour
            })
        )
        .blocks
    );
    assert!(!h.dir.path().join("session").join("CLAUDE.md").exists());
}

#[test]
fn consecutive_claude_turns_find_the_last_turns_marker_within_the_lookback() {
    let mut h = harness_with(settings);
    h.agents.inner.lock().unwrap().system_prompts = true;
    fill(&h.chat, 1_200);
    h.connect();
    h.say("user_local", "one");
    h.settle();
    h.say("user_local", "two");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.prompts.len(), 2);
    assert_eq!(inner.prompt_sets[0], inner.prompt_sets[1]);
    // The second turn has the first turn's marked block at the same place,
    // and its own marker at most 20 blocks later (the API's lookback).
    let (a, b) = (&inner.prompts[0], &inner.prompts[1]);
    let (ma, mb) = (markers(a)[0], markers(b)[0]);
    assert_eq!(texts(a)[..=ma], texts(b)[..=ma]);
    assert!(mb >= ma && mb - ma <= 20, "markers {ma} then {mb}");
}

#[test]
fn without_system_prompt_support_a_claude_turn_keeps_the_old_layout_and_its_claude_md() {
    let mut h = harness_with(settings);
    fill(&h.chat, 1_200);
    let view = h.chat.render_view().text;
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert!(inner.prompt_sets.is_empty());
    assert_eq!(inner.systems[0], None);
    assert_eq!(inner.specs[0].preset, None);
    assert_eq!(inner.prompts[0], turn_blocks(&view, &["hello".to_owned()]));
    assert_eq!(
        std::fs::read_to_string(h.dir.path().join("session").join("CLAUDE.md")).unwrap(),
        claude_md(None)
    );
}

#[test]
fn a_codex_turn_sends_the_view_first_and_the_messages_last_with_no_marker_and_no_system_prompt() {
    let mut h = harness_with(|dir| Settings {
        harness: "codex".into(),
        turn_preset: None,
        system_text: system_text(None, &Tools::Cli("/h/optchat/bin/chief".into())),
        ..settings(dir)
    });
    h.agents.inner.lock().unwrap().system_prompts = true;
    fill(&h.chat, 1_200);
    let view = h.chat.render_view().text;
    h.connect();
    h.say("user_local", "one");
    h.settle();
    h.say("user_local", "two");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert!(
        inner.prompt_sets.is_empty(),
        "a codex turn sets no system prompt"
    );
    assert_eq!(inner.specs[0].harness, "codex");
    assert_eq!(inner.specs[0].preset, None);
    assert_eq!(inner.prompts[0], turn_blocks(&view, &["one".to_owned()]));
    assert!(inner.prompts.iter().all(|b| markers(b).is_empty()));
    // Automatic prefix caching: the second turn's prompt starts with the
    // first turn's view pieces up to the first mark, byte for byte.
    let first = texts(&inner.prompts[0]);
    let second = texts(&inner.prompts[1]);
    assert_eq!(first[0], second[0], "the view's first piece is unchanged");
}

#[test]
fn a_four_breakpoint_refusal_reruns_the_turn_without_the_marker_and_later_turns_skip_it() {
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    let dir = tempfile::tempdir().unwrap();
    let s = settings(dir.path());
    // The refused request: acpmux records the turn's error, then answers
    // the prompt with it (no reply, no tool call).
    let script: Script = Box::new(|turn, blocks| {
        if turn == 0 {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                json!({"dir": "mux", "kind": "turn_error", "msg": {"error": MARKER_LIMIT}}),
            ]
        } else {
            default_script()(turn, blocks)
        }
    });
    let mut h = Harness::configured(
        dir,
        script,
        owner(),
        s,
        Arc::new(move |l: &str| sink.lock().unwrap().push(l.to_owned())),
    );
    {
        let mut inner = h.agents.inner.lock().unwrap();
        inner.system_prompts = true;
        inner.answer_error = Some(MARKER_LIMIT.into());
    }
    fill(&h.chat, 1_200);
    h.connect();
    h.say("user_local", "one");
    h.settle();
    {
        let inner = h.agents.inner.lock().unwrap();
        assert_eq!(
            inner.prompts.len(),
            2,
            "the refused prompt, then the same turn again"
        );
        assert_eq!(markers(&inner.prompts[0]).len(), 1);
        assert!(markers(&inner.prompts[1]).is_empty());
        assert_eq!(texts(&inner.prompts[0]), texts(&inner.prompts[1]));
        assert_ne!(
            inner.prompt_ids[0], inner.prompt_ids[1],
            "acpmux runs a prompt id once"
        );
    }
    // The second run answered: the reply is posted, not the 400.
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "{sends:?}");
    assert!(!sends[0].1.contains("cache_control"), "{sends:?}");
    assert!(
        lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.contains("cache_control") && l.contains("without")),
        "{:?}",
        lines.lock().unwrap()
    );
    h.say("user_local", "two");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.prompts.len(), 3);
    assert!(
        markers(&inner.prompts[2]).is_empty(),
        "later turns skip the marker"
    );
}

#[test]
fn each_turn_logs_its_cache_use_for_both_answer_shapes() {
    // Claude Code through acpmux: the whole turn's Anthropic usage.
    let claude = json!({"stopReason": "end_turn", "_meta": {"claude": {"usage": {"input_tokens": 3, "cache_read_input_tokens": 40000, "cache_creation_input_tokens": 900, "output_tokens": 50}}}});
    assert_eq!(
        answer_usage(&claude),
        Some((
            Usage {
                input: 3,
                cache_read: 40_000,
                cache_write: 900,
                output: 50
            },
            "turn total"
        ))
    );
    // codex-acp: ACP `usage` of the turn's last model request (cached input
    // reported as cache reads; OpenAI writes no separate cache-write count).
    let codex = json!({"stopReason": "end_turn", "usage": {"totalTokens": 30063, "inputTokens": 10, "cachedReadTokens": 30000, "outputTokens": 53, "thoughtTokens": 40}});
    assert_eq!(
        answer_usage(&codex),
        Some((
            Usage {
                input: 10,
                cache_read: 30_000,
                cache_write: 0,
                output: 53
            },
            "last request"
        ))
    );
    assert_eq!(answer_usage(&json!({"stopReason": "end_turn"})), None);
    // The turn's host.log line says what the numbers cover.
    let line = optchat_chief::turn::usage_line("turn:optchat:1:2", None, answer_usage(&codex));
    assert!(
        line.contains("last request read 30000 written 0 uncached 10 output 53"),
        "{line}"
    );
}

#[test]
fn the_harness_is_one_setting_for_turns_and_the_compactor() {
    use optchat_chief::host::harness_choice;
    assert_eq!(
        harness_choice(None, None, None),
        ("claude".to_owned(), "claude".to_owned()),
        "our Claude Code adapter on the user's own login, never the subrouter by default"
    );
    assert_eq!(
        harness_choice(Some("codex"), None, None),
        ("codex".to_owned(), "codex".to_owned()),
        "the compactor follows the Chief's harness"
    );
    assert_eq!(
        harness_choice(Some("codex"), Some("claude"), Some("claude-sr")),
        ("codex".to_owned(), "claude-sr".to_owned())
    );
    assert_eq!(
        harness_choice(None, Some("claude"), None),
        ("claude".to_owned(), "claude".to_owned()),
        "MUX_HARNESS still names the turn harness"
    );
}

#[test]
fn a_non_claude_harness_reads_its_instructions_from_agents_md_with_cli_memory_tools() {
    let text = system_text(None, &Tools::Cli("/h/optchat/bin/chief".into()));
    assert!(text.starts_with("You are Chief, an AI agent"));
    assert!(text.contains("`/h/optchat/bin/chief zoom ID N`"), "{text}");
    assert!(text.contains("`/h/optchat/bin/chief date ID`"), "{text}");
    assert!(
        text.contains("`/h/optchat/bin/chief spawn [--cwd DIR] \"task\""),
        "{text}"
    );
    assert!(text.contains("/h/optchat/bin/chief tell ID"), "{text}");
    assert!(!text.contains("MCP server `optchat`"), "{text}");
    assert_eq!(system_text(None, &Tools::Mcp), claude_md(None));
    let dir = tempfile::tempdir().unwrap();
    let paths = optchat_chief::paths::Paths::new(dir.path());
    paths.create().unwrap();
    let setup = optchat_chief::session_dir::SessionSetup {
        exe: "/x/optchat-chief".into(),
        cmux_mcp: None,
        env: Default::default(),
        instructions: None,
        tools: Tools::Cli(paths.bin.join("chief").display().to_string()),
    };
    optchat_chief::session_dir::write(&paths, &setup).unwrap();
    let agents_md = std::fs::read_to_string(paths.session.join("AGENTS.md")).unwrap();
    assert_eq!(agents_md, system_text(None, &setup.tools));
    assert!(!paths.session.join("CLAUDE.md").exists());
}

#[test]
fn chief_zoom_and_date_answer_from_the_live_memory() {
    use std::process::Command;
    let dir = tempfile::tempdir().unwrap();
    let chat = open_chat(&dir.path().join("chat"));
    chat.append(Kind::User, "hello\nworld").unwrap();
    chat.append(Kind::Talk, "hi").unwrap();
    assert!(chat.wait_idle(None, Some(WAIT)));
    let socket = dir.path().join("tools.sock");
    optchat_chief::tools::serve(&socket, chat.clone()).unwrap();
    let run = |args: &[&str]| {
        let out = Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
            .args(args)
            .arg("--socket")
            .arg(&socket)
            .output()
            .unwrap();
        (
            out.status.success(),
            String::from_utf8_lossy(&out.stdout).into_owned(),
        )
    };
    let (ok, text) = run(&["zoom", "0", "1"]);
    assert!(ok, "{text}");
    assert!(text.contains("hello\nworld"), "{text}");
    let (ok, text) = run(&["date", "0"]);
    assert!(ok, "{text}");
    assert!(text.contains("20"), "a date: {text}");
    let (ok, _) = run(&["zoom", "x", "1"]);
    assert!(!ok, "a bad id fails");
}

/// The durable-sessions lead excludes the Chief's own sessions from quit
/// counts and endAgents by tag: every turn session and every compactor
/// session carries `cmux.chief=<home id>` and `cmux.chief.role`; a child
/// keeps `mux.parent` only.
#[test]
fn the_chiefs_turn_and_compactor_sessions_carry_cmux_chief_and_children_do_not() {
    use optchat_chief::acpmux::{CHIEF_ROLE_TAG, CHIEF_TAG};
    let mut h = harness_with(settings);
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    {
        let inner = h.agents.inner.lock().unwrap();
        let tags = &inner.specs[0].tags;
        assert_eq!(tags.get(CHIEF_TAG).map(String::as_str), Some("h0me"));
        assert_eq!(tags.get(CHIEF_ROLE_TAG).map(String::as_str), Some("turn"));
        assert_eq!(tags.len(), 2);
    }
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "user: hi"}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
        ]
    }));
    let paths = optchat_chief::paths::Paths::new(&dir.path().join("mux"));
    let spec = optchat_chief::compactor::CompactorSpec {
        work: dir.path().join("work"),
        ..optchat_chief::compactor::compactor_spec(
            &paths,
            &dir.path().join("mux"),
            "claude-sr",
            optchat_chief::acpmux::Family::Claude,
            Some("claude-sonnet-5-5"),
        )
    };
    let home_id = spec.chief.clone();
    assert_eq!(
        home_id,
        optchat_chief::paths::home_id(&dir.path().join("mux"))
    );
    let compactor = optchat_chief::compactor::AcpmuxCompactor::new(
        agents.clone(),
        spec,
        optchat_chief::compactor::Slots::new(optchat_chief::compactor::COMPACTOR_SESSIONS),
    );
    let request = optchat_host::CompactRequest {
        node: optchat_host::NodeId::new(0, 0),
        system: "SYS".into(),
        context: "<chat>\n</chat>".into(),
        step: "STEP".into(),
        cut: None,
    };
    optchat_host::run_node(&compactor, &request).unwrap();
    let tags = agents.inner.lock().unwrap().specs[0].tags.clone();
    assert_eq!(tags.get(CHIEF_TAG), Some(&home_id));
    assert_eq!(
        tags.get(CHIEF_ROLE_TAG).map(String::as_str),
        Some("compactor")
    );
    // A child: no tags at creation; `agents spawn` then sets mux.parent.
    let flags = optchat_chief::cli::Flags::default();
    let child = optchat_chief::agents::child_spec(&flags, "kid", "/tmp");
    assert!(child.tags.is_empty(), "{:?}", child.tags);
}

#[test]
fn the_default_is_the_users_login_or_the_configured_coderouter_route() {
    use optchat_chief::host::{DEFAULT_HARNESS, default_harness};
    // `MUX_HARNESS` unset in the test process: the child takes the default.
    let flags = optchat_chief::cli::Flags::default();
    if std::env::var_os("MUX_HARNESS").is_none() {
        let child = optchat_chief::agents::child_spec(&flags, "kid", "/tmp");
        assert_eq!(child.harness, DEFAULT_HARNESS);
    }
    // No route configured (acpmux has no claude-cr): the user's own login,
    // never the subrouter even when it is installed.
    let plain = json!({"harnesses": {
        "claude": {"kind": "claude-stdio", "argv": ["/u/bin/claude"]},
        "claude-sr": {"kind": "claude-stdio", "argv": ["/u/bin/sr", "claude", "proxy"]},
    }});
    assert_eq!(default_harness(&plain), "claude");
    let admitted = optchat_chief::harness_gate::admit(&plain, default_harness(&plain)).unwrap();
    assert_eq!(admitted.argv0, "/u/bin/claude");
    // A configured route: the Chief uses it.
    let routed = json!({"harnesses": {
        "claude": {"kind": "claude-stdio", "argv": ["/u/bin/claude"]},
        "claude-cr": {"kind": "claude-stdio", "argv": ["/u/bin/coderouter", "team-route"]},
        "claude-sr": {"kind": "claude-stdio", "argv": ["/u/bin/sr", "claude", "proxy"]},
    }});
    assert_eq!(default_harness(&routed), "claude-cr");
    let admitted = optchat_chief::harness_gate::admit(&routed, "claude-cr").unwrap();
    assert_eq!(admitted.profile, "claude-cr");
    // A configured route acpmux could not run: refused with its reason
    // (posted in the Chief chat), never a silent move to another account.
    let down = json!({"harnesses": {
        "claude": {"kind": "claude-stdio", "argv": ["/u/bin/claude"]},
        "claude-cr": {"kind": "claude-stdio", "argv": ["/u/bin/cr", "team-route"],
                      "unavailable": "`cr team-route --version` failed: unknown command"},
    }});
    assert_eq!(default_harness(&down), "claude-cr");
    let refused = optchat_chief::harness_gate::admit(&down, "claude-cr").unwrap_err();
    assert!(
        refused.contains("unavailable") && refused.contains("unknown command"),
        "{refused}"
    );
    let shown = optchat_chief::harness_gate::refusal(&refused);
    assert!(shown.starts_with("refused: "), "{shown}");
    assert!(!shown.contains("Authentication"), "{shown}");
    // The subrouter still answers when it is asked for by name.
    assert_eq!(
        optchat_chief::harness_gate::admit(&routed, "claude-sr")
            .unwrap()
            .profile,
        "claude-sr"
    );
}

/// Live check 2026-10-04: acpmux records `turn_end` before it answers the
/// prompt, and only the answer carries the usage (Claude Code's
/// `_meta.claude.usage`, codex-acp's ACP `usage`); the turn's host.log line
/// still gets it.
#[test]
fn the_turn_line_reports_the_answers_usage_after_turn_end() {
    for (answer, expected) in [
        (
            json!({"stopReason": "end_turn", "usage": {"inputTokens": 10, "cachedReadTokens": 30000, "outputTokens": 53}}),
            "last request read 30000 written 0 uncached 10 output 53",
        ),
        (
            json!({"stopReason": "end_turn", "_meta": {"claude": {"usage": {"input_tokens": 2, "cache_read_input_tokens": 64893, "cache_creation_input_tokens": 11084, "output_tokens": 5}}}}),
            "turn total read 64893 written 11084 uncached 2 output 5",
        ),
    ] {
        let lines = Arc::new(Mutex::new(Vec::<String>::new()));
        let sink = lines.clone();
        let dir = tempfile::tempdir().unwrap();
        let s = settings(dir.path());
        let mut h = Harness::configured(
            dir,
            default_script(),
            owner(),
            s,
            Arc::new(move |l: &str| sink.lock().unwrap().push(l.to_owned())),
        );
        {
            let mut inner = h.agents.inner.lock().unwrap();
            inner.answer = Some(answer);
            inner.answer_delay = Some(std::time::Duration::from_millis(300));
        }
        h.connect();
        h.say("user_local", "hello");
        h.settle();
        let lines = lines.lock().unwrap();
        assert!(
            lines
                .iter()
                .any(|l| l.contains(" cache: ") && l.contains(expected)),
            "{expected}: {lines:?}"
        );
    }
}

/// The family (layout, isolation, cache key) comes from acpmux's harness
/// metadata, never from the harness's name: a `claude-*` name that runs
/// codex-acp is codex, and a Claude Code harness named anything is Claude.
#[test]
fn the_harness_family_comes_from_acpmuxs_metadata_not_the_name() {
    use optchat_chief::acpmux::{Family, harness_family};
    let answer = json!({"harnesses": {
        "claude-sr": {"kind": "claude-stdio", "argv": ["sr", "claude", "proxy"], "family": "claude"},
        "codex": {"argv": ["/u/.local/share/cmux-acp/current/bin/codex-acp"], "family": "codex"},
        "claude-router": {"argv": ["/opt/bin/codex-acp"], "family": "codex"},
        "work": {"kind": "claude-stdio", "argv": ["/opt/cc"]},
        "cx": {"argv": ["/opt/bin/codex-acp", "--profile", "x"]},
        "pi": {"argv": ["pi-acp"], "family": "pi"},
    }});
    for (name, family) in [
        ("claude-sr", Family::Claude),
        ("codex", Family::Codex),
        ("claude-router", Family::Codex),
        ("work", Family::Claude),
        ("cx", Family::Codex),
        ("pi", Family::Other),
    ] {
        assert_eq!(harness_family(&answer, name), Ok(family), "{name}");
    }
    let missing = harness_family(&answer, "claude").unwrap_err();
    assert!(missing.contains("claude"), "{missing}");
}

/// A codex turn session gets the Chief's stable turn cache key through the
/// turn preset's env (the cmux codex fork sends it as `prompt_cache_key`),
/// with or without the isolation; a Claude turn keeps its system prompt and
/// no key; another harness without isolation needs no preset.
#[test]
fn a_codex_turn_preset_carries_the_chiefs_turn_cache_key() {
    use optchat_chief::acpmux::Family;
    use optchat_chief::host::turn_preset;
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = optchat_chief::paths::Paths::new(&home);
    let id = optchat_chief::paths::home_id(&home);
    let key = format!("optchat-{id}-turn");
    let codex = turn_preset(&paths, &home, "codex", Family::Codex, true, "SYS").unwrap();
    assert_eq!(codex.name, format!("optchat-chief-codex-{id}"));
    assert_eq!(codex.env["CODEX_PROMPT_CACHE_KEY"], key);
    assert!(
        codex.args.is_empty(),
        "the preset args allowlist is untouched"
    );
    assert_eq!(codex.system_prompt, None);
    let bare = turn_preset(&paths, &home, "codex", Family::Codex, false, "SYS").unwrap();
    assert_eq!(
        bare.env,
        std::collections::BTreeMap::from([("CODEX_PROMPT_CACHE_KEY".to_owned(), key)])
    );
    let claude = turn_preset(&paths, &home, "claude-sr", Family::Claude, false, "SYS").unwrap();
    assert_eq!(claude.system_prompt.as_deref(), Some("SYS"));
    assert!(!claude.env.contains_key("CODEX_PROMPT_CACHE_KEY"));
    // claude-sr: one sticky subrouter account per Chief (subrouter PR 511),
    // so a turn reads the prompt cache the previous turn wrote.
    assert_eq!(
        claude.env.get("SUBROUTER_SESSION_KEY").map(String::as_str),
        Some(format!("optchat-{id}-turn").as_str())
    );
    assert_eq!(
        turn_preset(&paths, &home, "pi", Family::Other, false, "SYS"),
        None
    );
}

/// Taelin: "opus 5.5 medium is the one I use, it scores better". Turns run
/// at medium effort on both engines unless `OPTCHAT_CHIEF_EFFORT` names
/// another; on acpmux a harness of another family keeps its own default
/// (its effort names are not known).
#[test]
fn turns_run_at_medium_effort_on_both_engines() {
    use optchat_chief::acpmux::Family;
    use optchat_chief::effort::{native_effort, turn_effort};
    assert_eq!(turn_effort(None, Family::Claude).as_deref(), Some("medium"));
    assert_eq!(turn_effort(None, Family::Codex).as_deref(), Some("medium"));
    assert_eq!(turn_effort(None, Family::Other), None);
    assert_eq!(
        turn_effort(Some("high".into()), Family::Other).as_deref(),
        Some("high")
    );
    assert_eq!(native_effort(None), "medium");
    assert_eq!(native_effort(Some("high".into())), "high");
    // The turn session gets the setting's effort.
    let mut h = harness_with(settings);
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs[0].effort.as_deref(), Some("medium"));
}

/// Section 8 for a view of any size: our one marker sits at the end of the
/// stable older part of the view (a line end on a fixed grid, counted from
/// the view's start), and the next turn's request has a block boundary at
/// that same offset with the same bytes before it, so the API's lookback
/// from the next marker reads it. Measured 2026-10-06 on cmux-lawrence-2: a
/// small view had no marker, and each turn wrote the whole view again
/// (~8,000 tokens) while 90% of it was unchanged.
#[test]
fn the_marker_ends_the_stable_view_prefix_and_the_next_turn_keeps_that_boundary() {
    let mut h = harness_with(settings);
    h.agents.inner.lock().unwrap().system_prompts = true;
    fill(&h.chat, 120);
    h.connect();
    h.say("user_local", "one");
    h.settle();
    h.say("user_local", "two");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.prompts.len(), 2);
    // (offset of each block end, the text before it) over the view blocks.
    let ends = |blocks: &[Value]| -> Vec<(usize, String)> {
        let t = texts(blocks);
        let mut acc = String::new();
        t[..t.len() - 1]
            .iter()
            .map(|piece| {
                acc.push_str(piece);
                (acc.len(), acc.clone())
            })
            .collect()
    };
    let first = &inner.prompts[0];
    let marked = markers(first);
    assert_eq!(marked.len(), 1, "one marker of ours in a small view too");
    let at = marked[0];
    assert!(
        at + 1 < first.len() - 1,
        "the marker leaves the view's newest lines out"
    );
    let (offset, prefix) = ends(first)[at].clone();
    assert!(
        prefix.ends_with('\n'),
        "the marked piece ends at a line end"
    );
    let second = ends(&inner.prompts[1]);
    assert!(
        second.iter().any(|(o, p)| *o == offset && *p == prefix),
        "the next turn has a block boundary at the marker with the same bytes before it"
    );
    // And its own marker is at or after the first turn's.
    let next = markers(&inner.prompts[1])[0];
    assert!(second[next].0 >= offset);
}
