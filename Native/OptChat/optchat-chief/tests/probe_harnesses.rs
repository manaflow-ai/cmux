//! The acpmux daemon the Chief starts probes only the harnesses the Chief
//! can use (`ACPMUX_PROBE_HARNESSES`): a Claude-only Chief never starts
//! codex-acp at daemon start.

use optchat_chief::engine::EngineChoice;
use optchat_chief::host::probe_harnesses;

#[test]
fn a_claude_only_chief_probes_only_the_claude_routes() {
    let list = probe_harnesses(None, None, None, &EngineChoice::default());
    assert_eq!(list, "claude,claude-cr");
}

#[test]
fn every_harness_the_chief_is_set_to_is_probed() {
    let engine = EngineChoice {
        harness: Some("codex".into()),
        compactor_harness: Some("claude-sr".into()),
        ..EngineChoice::default()
    };
    let list = probe_harnesses(Some("claude-sr"), None, Some("opencode"), &engine);
    assert_eq!(list, "claude,claude-cr,claude-sr,codex,opencode");
}
