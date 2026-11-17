use super::*;
use crate::cli::command::{Cli, Command};
use clap::Parser;

fn parse(args: &[&str]) -> Result<(&'static str, Value)> {
    let cli = Cli::try_parse_from(args)?;
    match cli.command {
        Some(Command::Race(command)) => request(command),
        _ => anyhow::bail!("expected race command"),
    }
}

#[test]
fn race_cli_keeps_models_task_and_review_effort_separate() {
    let (method, value) = parse(&[
        "acpmux",
        "race",
        "new",
        "--parent",
        "source-chat",
        "-m",
        "codex/sol",
        "-m",
        "opencode/provider/model",
        "--reviewer",
        "claude/opus",
        "--reviewer-effort",
        "medium",
        "fix this\nwithout dropping this line",
    ])
    .unwrap();
    assert_eq!(method, "_acpmux/race/start");
    assert_eq!(value.get("parent"), Some(&json!("source-chat")));
    assert_eq!(value.get("prompt"), Some(&json!("fix this\nwithout dropping this line")));
    assert_eq!(value.pointer("/candidates/1/model"), Some(&json!("provider/model")));
    assert_eq!(value.pointer("/reviewer/effort"), Some(&json!("medium")));
    assert!(value.pointer("/candidates/0/effort").is_none());
}

#[test]
fn race_cli_rejects_missing_task_and_single_candidate_before_connecting() {
    assert!(
        parse(&["acpmux", "race", "new", "-m", "codex", "--reviewer", "claude", "task"]).is_err()
    );
    assert!(
        parse(&[
            "acpmux",
            "race",
            "new",
            "-m",
            "codex",
            "-m",
            "claude",
            "--reviewer",
            "codex",
            " "
        ])
        .is_err()
    );
}

#[test]
fn race_cli_reads_and_stops_only_the_named_race_under_the_named_parent() {
    for (verb, method) in [("show", "get"), ("stop", "cancel")] {
        let (actual, params) =
            parse(&["acpmux", "race", verb, "race-a", "--parent", "chat-a"]).unwrap();
        assert_eq!(actual, format!("_acpmux/race/{method}"));
        assert_eq!(params, json!({"raceId": "race-a", "parent": "chat-a"}));
    }
    let (_, params) = parse(&["acpmux", "race", "ls"]).unwrap();
    assert!(params.get("parent").is_none());
}

#[test]
fn race_cli_rejects_empty_harness_or_explicit_model() {
    for spec in ["", "/model", "codex/", "codex/ "] {
        assert!(target(spec, None).is_err(), "accepted {spec:?}");
    }
}
