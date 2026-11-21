use super::{Cli, Command};
use clap::Parser;

#[test]
fn config_set_accepts_session_resource_assignment() {
    let cli = Cli::try_parse_from(["acpmux", "config", "--set", "session.memory_mb=6144"]).unwrap();
    match cli.command {
        Some(Command::Config { set: Some(value), .. }) => {
            assert_eq!(value, "session.memory_mb=6144")
        }
        _ => panic!("unexpected command"),
    }
}
