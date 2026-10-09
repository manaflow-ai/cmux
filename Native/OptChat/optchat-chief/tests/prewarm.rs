//! The next turn's harness is already up (parity item 4): the Chief hints
//! acpmux's session pool (`_acpmux/prewarm`) with the exact shape of its
//! next turn session (harness profile, preset, session directory) when
//! acpmux connects and after every turn, so the next `session/new` takes a
//! started harness with its MCP servers up instead of a cold start. Each
//! turn still gets a fresh conversation: the view is its whole context.

mod common;

use common::*;

fn shapes(
    h: &Harness,
) -> (
    Vec<(String, Option<String>, std::path::PathBuf)>,
    Vec<optchat_chief::acpmux::SessionSpec>,
) {
    let inner = h.agents.inner.lock().unwrap();
    (inner.prewarms.clone(), inner.specs.clone())
}

fn hints_the_turn_session_shape(system_prompts: bool) {
    let mut h = Harness::new(default_script());
    h.agents.inner.lock().unwrap().system_prompts = system_prompts;
    h.connect();
    let (hints, _) = shapes(&h);
    assert_eq!(hints.len(), 1, "one hint when acpmux connects: {hints:?}");
    h.say("user_local", "one");
    h.settle();
    h.say("user_local", "two");
    h.settle();
    let (hints, specs) = shapes(&h);
    assert_eq!(specs.len(), 2, "{specs:?}");
    assert_eq!(hints.len(), 3, "one more hint after each turn: {hints:?}");
    for spec in &specs {
        let shape = (spec.harness.clone(), spec.preset.clone(), spec.cwd.clone());
        assert!(
            hints.iter().all(|h| *h == shape),
            "every hint has the turn session's shape {shape:?}: {hints:?}"
        );
    }
}

#[test]
fn hints_the_turn_session_shape_in_the_cached_layout() {
    hints_the_turn_session_shape(true);
}

#[test]
fn hints_the_turn_session_shape_without_a_preset_system_prompt() {
    hints_the_turn_session_shape(false);
}
