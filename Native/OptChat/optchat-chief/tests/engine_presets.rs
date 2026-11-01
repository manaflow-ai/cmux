//! `chief engine set --preset opus|hybrid|codex` (Leo, 2026-10-23: "we can
//! have vanilla all opus 5.5 med chief, we can have forced hybrid chief, and
//! we can have pure codex chief").

use optchat_chief::engine::{EngineChoice, apply_flags};

fn flags(words: &[&str]) -> optchat_chief::cli::Flags {
    optchat_chief::cli::Flags::parse(&words.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>())
}

fn set(choice: EngineChoice, words: &[&str]) -> Result<EngineChoice, String> {
    let mut all = vec!["engine", "set"];
    all.extend_from_slice(words);
    apply_flags(choice, &flags(&all))
}

/// A choice with every field a preset owns set to something else, and the
/// reaction classifier set, which no preset touches.
fn busy() -> EngineChoice {
    EngineChoice {
        harness: Some("opencode".into()),
        model: Some("m".into()),
        effort: Some("max".into()),
        compactor_harness: Some("opencode".into()),
        compactor_model: Some("cm".into()),
        speed: Some("fast".into()),
        compactor_speed: Some("fast".into()),
        classifier_model: Some("classifier".into()),
        reactions_can_wake: Some(false),
        subagent_routing: Some("auto".into()),
        subagent_harness: Some("opencode".into()),
        ..EngineChoice::default()
    }
}

#[test]
fn opus_preset_is_opus_5_5_medium_everywhere() {
    let c = set(busy(), &["--preset", "opus"]).unwrap();
    assert_eq!(c.harness.as_deref(), Some("claude"));
    assert_eq!(c.model.as_deref(), Some("claude-opus-5-5"));
    assert_eq!(c.effort.as_deref(), Some("medium"));
    assert_eq!(c.speed, None, "Claude Code has no fast mode");
    // The compactor and subagents follow the Claude route.
    assert_eq!(c.compactor_harness, None);
    assert_eq!(c.compactor_model, None);
    assert_eq!(c.compactor_speed, None);
    assert_eq!(c.subagent_harness, None);
    assert_eq!(c.subagent_routing.as_deref(), Some("off"));
    // Untouched.
    assert_eq!(c.classifier_model.as_deref(), Some("classifier"));
    assert_eq!(c.reactions_can_wake, Some(false));
}

#[test]
fn hybrid_preset_forces_every_subagent_onto_codex() {
    let c = set(busy(), &["--preset", "hybrid"]).unwrap();
    assert_eq!(c.harness.as_deref(), Some("claude"));
    assert_eq!(c.model.as_deref(), Some("claude-opus-5-5"));
    assert_eq!(c.effort.as_deref(), Some("medium"));
    assert_eq!(c.subagent_harness.as_deref(), Some("codex"));
    // Forced: a spawn may not name another harness.
    assert_eq!(c.subagent_routing.as_deref(), Some("off"));
    assert_eq!(c.compactor_harness, None);
}

#[test]
fn codex_preset_is_codex_everywhere() {
    let c = set(busy(), &["--preset", "codex"]).unwrap();
    assert_eq!(c.harness.as_deref(), Some("codex"));
    assert_eq!(c.model, None, "codex's own default model");
    assert_eq!(c.effort, None);
    assert_eq!(c.speed.as_deref(), Some("fast"));
    assert_eq!(c.compactor_harness.as_deref(), Some("codex"));
    assert_eq!(c.compactor_model, None, "never a Claude model on codex");
    assert_eq!(c.subagent_harness.as_deref(), Some("codex"));
    assert_eq!(c.subagent_routing.as_deref(), Some("off"));
}

#[test]
fn other_flags_adjust_a_preset_and_unknown_presets_are_refused() {
    let c = set(
        EngineChoice::default(),
        &[
            "--preset",
            "codex",
            "--model",
            "gpt-6-astra",
            "--effort",
            "high",
        ],
    )
    .unwrap();
    assert_eq!(c.harness.as_deref(), Some("codex"));
    assert_eq!(c.model.as_deref(), Some("gpt-6-astra"));
    assert_eq!(c.effort.as_deref(), Some("high"));
    let err = set(EngineChoice::default(), &["--preset", "sonnet"]).unwrap_err();
    assert!(err.contains("opus, hybrid, codex"), "{err}");
    assert!(optchat_chief::engine::USAGE.contains("--preset opus|hybrid|codex"));
}
