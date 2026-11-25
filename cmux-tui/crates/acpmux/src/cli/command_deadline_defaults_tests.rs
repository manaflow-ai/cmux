use super::{Cli, Command};
use clap::Parser;

#[test]
fn send_waits_for_a_live_peer_by_default() {
    let cli = Cli::try_parse_from(["acpmux", "send", "session", "slow reply"]).unwrap();
    match cli.command {
        Some(Command::Send { stall, .. }) => assert_eq!(stall, 0),
        _ => panic!("expected send command"),
    }
}

#[test]
fn explicit_stall_remains_a_caller_choice() {
    let cli = Cli::try_parse_from(["acpmux", "send", "session", "--stall", "7"]).unwrap();
    match cli.command {
        Some(Command::Send { stall, .. }) => assert_eq!(stall, 7),
        _ => panic!("expected send command"),
    }
}

/// `acpmux send --gather` (`hub/cold_wake.rs`): a named sender's message or notice that waits
/// for the chat's batch, and so never waits for its reply.
#[test]
fn a_gather_send_parses_and_never_waits_for_a_reply() {
    let parse = |argv: &[&str]| Cli::try_parse_from(argv);
    assert!(parse(&["acpmux", "send", "c", "hi", "--gather", "--from", "forum"]).is_ok());
    let notice = [
        "acpmux",
        "send",
        "c",
        "--notice",
        "--severity",
        "info",
        "--title",
        "T",
        "--sender",
        "slack",
        "--gather",
    ];
    assert!(parse(&notice).is_ok());
    for clash in ["--wait", "--quiet"] {
        assert!(parse(&["acpmux", "send", "c", "hi", "--gather", clash]).is_err(), "{clash}");
    }
}
