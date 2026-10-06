//! `chief spawn|tell|zoom|date WORDS` from a turn's shell (chwsr4/chwsr5
//! E2E: the Chief ran `chief spawn --help` to read the options and started a
//! subagent whose task was `--help`).

use optchat_chief::tools::{Call, Command, command, usage};

#[test]
fn help_prints_the_usage_and_starts_nothing() {
    for tool in ["spawn", "tell", "zoom", "date"] {
        for flag in ["--help", "-h"] {
            assert_eq!(
                command(tool, &[flag]),
                Ok(Command::Help(usage(tool))),
                "{tool} {flag}"
            );
        }
    }
    assert_eq!(
        command("spawn", &["Reply PONG.", "--help"]),
        Ok(Command::Help(usage("spawn")))
    );
}

#[test]
fn tasks_are_still_tasks() {
    assert_eq!(
        command("spawn", &["Reply PONG."]),
        Ok(Command::Call(Call::Spawn {
            tasks: vec!["Reply PONG.".into()]
        }))
    );
    assert_eq!(command("spawn", &[]), Ok(Command::Usage(usage("spawn"))));
}
