//! A Claude Code harness under its own family (`claude-sr2`: Claude Code
//! through subrouter2, `~/.config/cmux/harnesses/claude-sr2.toml`) is a
//! Claude harness to the Chief, so its turns and subagents keep the Claude
//! presets (Lawrence 2026-10-18: "make sure that cmux-home talks to sr2").

use optchat_chief::acpmux::{Family, harness_family};
use optchat_chief::harness_gate::admit;
use serde_json::{Value, json};

fn answer() -> Value {
    json!({"harnesses": {
        "claude": {"kind": "claude-stdio", "argv": ["/u/.local/bin/claude"], "family": "claude"},
        "claude-sr2": {"kind": "claude-stdio", "argv": ["/u/.local/bin/sr2", "claude"], "family": "claude-sr2"},
        "sr2-acp": {"kind": "acp", "argv": ["/u/bin/some-acp"], "family": "claude-sr2"},
        "codex": {"argv": ["/x/codex-acp"], "family": "codex"},
    }, "defaultHarness": "claude"})
}

#[test]
fn a_claude_stdio_harness_with_its_own_family_is_claude() {
    assert_eq!(harness_family(&answer(), "claude-sr2"), Ok(Family::Claude));
    assert_eq!(harness_family(&answer(), "claude"), Ok(Family::Claude));
    assert_eq!(harness_family(&answer(), "codex"), Ok(Family::Codex));
}

#[test]
fn an_acp_harness_with_an_unknown_family_stays_other() {
    assert_eq!(harness_family(&answer(), "sr2-acp"), Ok(Family::Other));
}

#[test]
fn the_gate_admits_claude_sr2_as_a_claude_stdio_profile() {
    let admitted = admit(&answer(), "claude-sr2").expect("claude-sr2 is admitted");
    assert_eq!(admitted.profile, "claude-sr2");
    assert_eq!(admitted.kind, "claude-stdio");
    assert_eq!(admitted.family, Family::Claude);
}

/// With no harness set, the Chief, its compactor and its subagents run the
/// user's own Claude CLI (acpmux's `claude`: the `claude` on the login
/// shell's PATH, with the user's `~/.claude/settings.json` and login), even
/// when the sr2 harness file is installed and runnable (Lawrence
/// 2026-10-19: "make sure Chief, by default, will talk to the correct
/// Claude, using the user's Claude CLI"). sr2 is an explicit choice
/// (`chief engine set --harness claude-sr2`), or the fallback only when
/// acpmux has no usable `claude`. A configured CodeRouter route still wins.
#[test]
fn the_default_is_the_users_own_claude_cli_even_when_sr2_runs() {
    use optchat_chief::host::default_harness;
    assert_eq!(default_harness(&answer()), "claude");
    let admitted = admit(&answer(), default_harness(&answer())).unwrap();
    assert_eq!(admitted.argv0, "/u/.local/bin/claude");
    let down = json!({"harnesses": {
        "claude": {"kind": "claude-stdio", "argv": ["/u/.local/bin/claude"]},
        "claude-sr2": {"kind": "claude-stdio", "argv": ["/u/.local/bin/sr2", "claude"],
                       "unavailable": "`sr2 --version` failed"},
    }});
    assert_eq!(default_harness(&down), "claude");
    // No usable `claude` on the PATH: sr2, when it runs, rather than a
    // harness that refuses every turn.
    let no_cli = json!({"harnesses": {
        "claude": {"kind": "claude-stdio", "argv": ["claude"],
                   "unavailable": "claude was not found on PATH"},
        "claude-sr2": {"kind": "claude-stdio", "argv": ["/u/.local/bin/sr2", "claude"]},
    }});
    assert_eq!(default_harness(&no_cli), "claude-sr2");
    let routed = json!({"harnesses": {
        "claude": {"kind": "claude-stdio", "argv": ["/u/.local/bin/claude"]},
        "claude-cr": {"kind": "claude-stdio", "argv": ["/u/bin/coderouter", "team-route"]},
        "claude-sr2": {"kind": "claude-stdio", "argv": ["/u/.local/bin/sr2", "claude"]},
    }});
    assert_eq!(default_harness(&routed), "claude-cr");
}

/// The compactor of a Chief with an empty engine.json runs the same CLI as
/// its turns: the user's own `claude`, not sr2.
#[test]
fn an_empty_engine_compacts_on_the_users_own_claude_cli() {
    use optchat_chief::host::{compactor_harness_for, default_harness};
    let engine = optchat_chief::engine::EngineChoice::default();
    let turn = default_harness(&answer());
    assert_eq!(
        compactor_harness_for(&answer(), None, turn, &engine),
        "claude"
    );
    // An explicit choice still wins.
    let set = optchat_chief::engine::EngineChoice {
        harness: Some("claude-sr2".into()),
        ..Default::default()
    };
    assert_eq!(
        compactor_harness_for(&answer(), None, turn, &set),
        "claude-sr2"
    );
}

/// `chief engine show` names the CLI each role runs (path and version), from
/// what the host resolved at its start.
#[test]
fn engine_show_prints_the_resolved_cli_of_each_role() {
    use optchat_chief::engine::{ResolvedEngine, ResolvedHarness, save_resolved};
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let claude = ResolvedHarness {
        harness: "claude".into(),
        kind: "claude-stdio".into(),
        argv0: "/u/.local/bin/claude".into(),
        version: "2.1.303 (Claude Code)".into(),
    };
    let resolved = ResolvedEngine {
        turn: Some(claude.clone()),
        compactor: Some(claude.clone()),
        subagent: Some(claude),
    };
    save_resolved(&home, &resolved).unwrap();
    let flags = optchat_chief::cli::Flags::parse(&[
        "engine".to_owned(),
        "show".to_owned(),
        "--mux-home".to_owned(),
        home.display().to_string(),
    ]);
    let out = optchat_chief::engine::run(&flags).unwrap();
    for role in ["turn", "compactor", "subagent"] {
        assert!(
            out.contains(&format!(
                "{role}: claude (claude-stdio, /u/.local/bin/claude, 2.1.303 (Claude Code))"
            )),
            "{out}"
        );
    }
}
