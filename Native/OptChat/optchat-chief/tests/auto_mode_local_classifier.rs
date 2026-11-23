//! https://github.com/manaflow-ai/cmux/issues/37356: a Chief in auto mode
//! ran none of its commands. Claude Code 2.1.319 judged each call with the
//! API's server-side safety check; responses came back with no verdict
//! (`server_no_result`), and with no local classifier to fall back to it
//! denied every classified call ("auto mode has no safety result for this
//! call"). Every Chief Claude session now runs auto mode on Claude Code's
//! local classifier, which still judges each call and has its own retries.

use optchat_chief::acpmux::Family;
use optchat_chief::host::{subagent_preset, turn_preset};
use optchat_chief::session_dir::{AUTO_MODE_SERVER_ENV, claude_session_env};

#[test]
fn every_chief_claude_session_judges_auto_mode_locally() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = optchat_chief::paths::Paths::new(&home);
    let want = "0".to_owned();
    for harness in ["claude", "claude-sr", "claude-sr2"] {
        for isolate in [true, false] {
            let turn = turn_preset(&paths, &home, harness, Family::Claude, isolate, "SYS").unwrap();
            assert_eq!(
                turn.env.get(AUTO_MODE_SERVER_ENV),
                Some(&want),
                "turn {harness} isolate={isolate}: {:?}",
                turn.env
            );
            let sub = subagent_preset(
                &paths,
                &home,
                "optchat-sub-x".into(),
                harness,
                Family::Claude,
                isolate,
                "SUB",
                &Default::default(),
            );
            assert_eq!(
                sub.env.get(AUTO_MODE_SERVER_ENV),
                Some(&want),
                "subagent {harness} isolate={isolate}: {:?}",
                sub.env
            );
        }
    }
    let compactors =
        optchat_chief::compactor::compactor_presets(&paths, &home, "claude", Family::Claude);
    assert!(!compactors.is_empty());
    for preset in compactors {
        assert_eq!(
            preset.env.get(AUTO_MODE_SERVER_ENV),
            Some(&want),
            "{}: {:?}",
            preset.name,
            preset.env
        );
    }
}

/// A Codex or other harness has no Claude auto mode: no Claude switch.
#[test]
fn other_harnesses_get_no_claude_auto_mode_switch() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = optchat_chief::paths::Paths::new(&home);
    let codex = turn_preset(&paths, &home, "codex", Family::Codex, true, "SYS").unwrap();
    assert!(
        !codex.env.contains_key(AUTO_MODE_SERVER_ENV),
        "{:?}",
        codex.env
    );
}

/// The Claude session env keeps the quiet settings next to the switch.
#[test]
fn the_claude_session_env_keeps_the_quiet_settings() {
    let env = claude_session_env();
    assert_eq!(env[AUTO_MODE_SERVER_ENV], "0");
    assert_eq!(env["DISABLE_AUTOUPDATER"], "1");
}
