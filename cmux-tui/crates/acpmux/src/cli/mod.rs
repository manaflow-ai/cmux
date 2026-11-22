//! The `acpmux` command line: `entry` is the program (the `acpmux` binary
//! and `cmux acp` both call it); `command` is the argument grammar; `run`
//! dispatches a parsed command; `output` formats what the daemon answers;
//! `orchestrate` holds the commands other agents and scripts call; `handoff`
//! is `continue`; `errors` maps every failure to one exit code and envelope.

pub mod chats;
pub mod command;
pub mod entry;
pub mod errors;
pub mod handoff;
pub mod harness;
pub mod harness_folder;
pub mod harness_login;
pub mod harness_registry;
pub mod harness_run;
pub mod harness_secret;
pub mod hosts;
pub mod orchestrate;
pub mod output;
pub mod run;
pub mod session_folder;
pub mod shutdown;
pub mod stdio;
