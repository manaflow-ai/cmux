//! The `acpmux` command line: `entry` is the program (the `acpmux` binary
//! and `cmux acp` both call it); `command` is the argument grammar; `run`
//! dispatches a parsed command; `output` formats what the daemon answers;
//! `orchestrate` holds the commands other agents and scripts call; `handoff`
//! is `continue`; `errors` maps every failure to one exit code and envelope.

pub mod beads;
pub mod chats;
pub mod cli_agent;
pub mod command;
pub mod command_host;
pub mod entry;
pub mod errors;
pub mod forum;
pub mod handoff;
pub mod harness;
pub mod harness_folder;
pub mod harness_login;
pub mod harness_registry;
pub mod harness_run;
pub mod harness_secret;
pub mod host_budget;
pub mod host_candidates;
pub mod host_enroll;
pub mod host_peering;
pub mod host_steps;
pub mod hosts;
pub mod orchestrate;
pub mod output;
pub mod pairing;
pub mod peer_status;
pub mod place;
pub mod process;
pub mod resolve;
pub mod retry;
pub mod run;
pub(crate) mod send_relay;
pub mod sender;
pub mod session_folder;
pub mod session_limits;
pub mod shutdown;
pub mod stdio;
pub(crate) mod steer_reply;
pub mod task;
pub mod uniichat_agent;
pub(crate) mod unknown_flag;
pub mod worktree;
