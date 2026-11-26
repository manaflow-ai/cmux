use super::*;
use serde_json::json;

#[test]
fn preflight_keeps_unknown_dirt_distinct_from_clean_and_running_from_other_refusals() {
    let unknown = serde_json::to_value(Preflight { running: true, dirty: None }).unwrap();
    assert_eq!(unknown, json!({"running": true, "dirty": null}));
    let both = serde_json::to_value(Preflight { running: true, dirty: Some(true) }).unwrap();
    assert_eq!(both, json!({"running": true, "dirty": true}));
    let starting = json!({"status": "ready", "turn": {"turnId": "one"}});
    assert_eq!(session_refusal_code(&starting, false), Some("running_turn"));
    assert_eq!(session_refusal_code(&starting, true), None);
    assert_eq!(session_refusal_code(&json!({"status": "running", "moving": true}), false), None);
    assert_eq!(session_refusal_code(&json!({"status": "running", "movedTo": {}}), false), None);
}

#[test]
fn after_turn_and_interrupt_are_distinct_mutually_exclusive_cli_choices() {
    use crate::cli::command::{Cli, Command, flatten};
    use clap::Parser;
    let args = ["acpmux", "session", "move", "chat", "--machine", "auto", "--after-turn"];
    let cli = Cli::try_parse_from(args).unwrap();
    assert!(matches!(
        flatten(cli.command.unwrap()),
        Command::MoveSessions(a) if a.after_turn && !a.interrupt
    ));
    let conflict = args.into_iter().chain(["--interrupt"]);
    assert!(Cli::try_parse_from(conflict).is_err());
}
