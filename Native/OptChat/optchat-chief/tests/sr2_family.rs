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
