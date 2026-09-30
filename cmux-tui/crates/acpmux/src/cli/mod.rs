//! The `acpmux` command line: `entry` is the program (the `acpmux` binary
//! and `cmux acp` both call it); `command` is the argument grammar; `run`
//! dispatches a parsed command; `output` formats what the daemon answers;
//! `orchestrate` holds the commands other agents and scripts call; `errors`
//! maps every failure to one exit code and envelope.

pub mod command;
pub mod entry;
pub mod errors;
pub mod hosts;
pub mod orchestrate;
pub mod output;
pub mod run;
pub mod stdio;
