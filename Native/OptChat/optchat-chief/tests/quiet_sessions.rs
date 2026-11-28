//! The Chief's Claude sessions (turn, compactor, subagent) skip Claude
//! Code's background plugin auto-update, which runs `git` in
//! ~/.claude/plugins/marketplaces, outside the Chief home (2-hour soak,
//! 2026-10-09). `DISABLE_AUTOUPDATER=1` in each preset's env turns it off
//! for these sessions only (Claude Code 2.1.295: plugin autoupdate skips
//! when the auto-updater is disabled); the user's ~/.claude stays as it is.

use std::collections::BTreeMap;

use optchat_chief::acpmux::Family;
use optchat_chief::compactor::compactor_presets;
use optchat_chief::host::{subagent_preset, turn_preset};
use optchat_chief::paths::Paths;

fn quiet(env: &BTreeMap<String, String>, what: &str) {
    assert_eq!(
        env.get("DISABLE_AUTOUPDATER").map(String::as_str),
        Some("1"),
        "{what}: {env:?}"
    );
}

#[test]
fn every_chief_claude_session_skips_the_plugin_auto_update() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = Paths::new(&home);
    for isolate in [true, false] {
        for harness in ["claude", "claude-sr"] {
            let turn = turn_preset(&paths, &home, harness, Family::Claude, isolate, "SYS").unwrap();
            quiet(&turn.env, &format!("turn {harness} isolate={isolate}"));
            let sub = subagent_preset(
                &paths,
                &home,
                "sub".into(),
                harness,
                Family::Claude,
                isolate,
                "SYS",
                &BTreeMap::new(),
            );
            quiet(&sub.env, &format!("subagent {harness} isolate={isolate}"));
        }
    }
    for preset in compactor_presets(&paths, &home, "claude-sr", Family::Claude) {
        quiet(&preset.env, &preset.name);
    }
}
