use super::*;
use crate::cli::command::{Cli, Command, flatten};
use clap::Parser;

fn parse(args: &[&str]) -> Value {
    let command = Cli::try_parse_from(args).unwrap().command.unwrap();
    let Command::Session(command) = flatten(command) else { panic!("mesh command flattened away") };
    request(command).unwrap()
}

#[test]
fn mesh_cli_keeps_start_policy_and_exact_recipients() {
    let start = parse(&[
        "acpmux",
        "session",
        "start",
        "review",
        "--machine",
        "worker",
        "-m",
        "codex/gpt-6-astra",
        "--policy",
        "ask",
        "--cwd",
        "/remote",
        "--idempotency-key",
        "start-test",
    ]);
    assert_eq!(start["op"], "start");
    assert_eq!(start["to"], json!({"host": "worker"}));
    assert_eq!(start["params"]["_meta"]["acpmux"]["policy"], "ask");
    assert_eq!(start["params"]["_meta"]["acpmux"]["harness"], "codex");
    let stop = parse(&["acpmux", "session", "stop", "worker/review", "--mesh"]);
    assert_eq!(stop["to"], json!({"host": "worker", "name": "review"}));
    let resume = parse(&["acpmux", "session", "resume", "stable-id", "--mesh", "--id"]);
    assert_eq!(resume["to"], json!({"sessionId": "stable-id"}));
    let receipt = parse(&["acpmux", "session", "receipt", "msg_test"]);
    assert_eq!(receipt, json!({"receipt": "msg_test"}));
}

/// `session stop --id ID` and `session resume --id ID` need no `--mesh`: they run as the
/// positional forms do, on this daemon's resolver.
#[test]
fn id_without_mesh_runs_the_local_command() {
    let local = |args: &[&str]| flatten(Cli::try_parse_from(args).unwrap().command.unwrap());
    let id = "0b7e7c2e-6f43-4a51-9d0e-2a4c3b1f5e6d";
    for argv in [
        &["acpmux", "session", "stop", "--id", id][..],
        &["acpmux", "session", "stop", id, "--id"][..],
        &["acpmux", "session", "kill", "--id", id, "--purge"][..],
    ] {
        match local(argv) {
            Command::Kill { session, purge, condition } => {
                assert_eq!(session, id, "{argv:?}");
                assert_eq!(purge, argv.contains(&"--purge"), "{argv:?}");
                // Without --if-idle the stop is the plain one, as before.
                assert_eq!(condition, crate::cli::command::StopIf::default(), "{argv:?}");
            }
            _ => panic!("{argv:?} did not run the local stop"),
        }
    }
    match local(&["acpmux", "session", "resume", "--id", id]) {
        Command::ResumeQueue { session, .. } => assert_eq!(session, id),
        _ => panic!("resume --id did not run the local resume"),
    }
    // `--idempotency-key` is still a mesh-only flag.
    assert!(
        Cli::try_parse_from(["acpmux", "session", "stop", id, "--idempotency-key", "k"]).is_err()
    );
    // With --mesh, --id still names the exact id.
    let stop = parse(&["acpmux", "session", "stop", "stable-id", "--mesh", "--id"]);
    assert_eq!(stop["to"], json!({"sessionId": "stable-id"}));
}

/// `session stop --if-idle [--expect-revision REV]` runs the local stop with its condition;
/// a revision needs --if-idle, and the mesh hub's stop takes neither.
#[test]
fn if_idle_runs_the_local_stop_with_its_condition() {
    use crate::cli::command::StopIf;
    let local = |args: &[&str]| flatten(Cli::try_parse_from(args).unwrap().command.unwrap());
    let condition = |args: &[&str]| match local(args) {
        Command::Kill { condition, .. } => condition,
        _ => panic!("{args:?} did not run the local stop"),
    };
    assert_eq!(
        condition(&["acpmux", "session", "stop", "lane", "--if-idle", "--expect-revision", "42"]),
        StopIf { if_idle: true, expect_revision: Some(42) }
    );
    assert_eq!(
        condition(&["acpmux", "session", "stop", "lane", "--if-idle", "--purge"]),
        StopIf { if_idle: true, expect_revision: None }
    );
    assert_eq!(condition(&["acpmux", "session", "stop", "lane"]), StopIf::default());
    for argv in [
        &["acpmux", "session", "stop", "lane", "--expect-revision", "42"][..],
        &["acpmux", "session", "stop", "lane", "--mesh", "--if-idle"][..],
        &["acpmux", "session", "stop", "lane", "--if-idle", "--expect-revision", "-1"][..],
    ] {
        assert!(Cli::try_parse_from(argv).is_err(), "{argv:?} parsed");
    }
}
