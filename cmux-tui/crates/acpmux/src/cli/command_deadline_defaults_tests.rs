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
