//! The `acpmux` command line: `entry` is the program (the `acpmux` binary
//! and `cmux acp` both call it); `command` is the argument grammar; `run`
//! dispatches a parsed command; `output` formats what the daemon answers;
//! `orchestrate` holds the commands other agents and scripts call; `handoff`
//! is `continue`; `errors` maps every failure to one exit code and envelope.

pub mod app_bridge;
pub mod app_open;
pub(crate) mod archive;
pub mod beads;
pub mod bg;
pub(crate) use crate::bounded_child;
pub mod account;
pub mod bridge;
pub mod chats;
pub mod cli_agent;
pub mod cloud_join;
pub mod command;
pub mod command_host;
pub mod command_new;
pub(crate) mod consent_admin;
pub mod daemon_service;
pub mod daemon_stats;
pub mod desktop;
pub mod detach;
pub mod entry;
pub mod errors;
pub mod forum;
pub mod gh_shim;
pub mod group;
pub mod handoff;
pub mod harness;
pub mod harness_folder;
pub mod harness_login;
pub mod harness_registry;
pub mod harness_run;
pub mod harness_secret;
pub(crate) mod help_examples;
pub mod host_agents;
pub mod host_approvals;
pub mod host_budget;
pub mod host_candidates;
pub mod host_enroll;
pub mod host_join_doctor;
pub mod host_peering;
pub(crate) mod host_sandbox;
pub mod host_ssh_key;
pub mod host_steps;
pub mod host_vault;
pub mod hosts;
pub mod join_input;
pub(crate) mod last_reply;
pub mod ledger;
pub(crate) mod list_read;
pub(crate) mod ls_far;
pub(crate) mod ls_ssh;
pub mod ls_table;
pub mod machine_auth;
pub(crate) mod owned_child;
pub(crate) use crate::machine_consent;
pub mod machine_deps;
pub mod mesh_control;
pub(crate) mod new_relay;
pub use crate::mesh_node_key;
pub mod fork_run;
pub mod notices;
pub mod orchestrate;
pub mod output;
pub mod pairing;
pub mod peer_status;
pub mod place;
pub mod process;
#[cfg(unix)]
pub mod process_census;
#[cfg(unix)]
pub mod process_owner;

/// Whether `argv` runs `daemon run` (the acpmux daemon). Every OS: the vault egress proxy asks.
pub(crate) fn is_daemon_run(argv: &[String]) -> bool {
    argv.windows(2).any(|w| matches!(w, [a, b] if a == "daemon" && b == "run"))
}
pub mod race;
pub(crate) mod reply_address;
pub mod resolve;
pub mod resume_here;
pub mod resume_here_ask;
pub mod retry;
pub mod run;
pub mod search_all;
pub(crate) mod select;
pub(crate) mod send_notice;
pub(crate) mod send_relay;
pub mod sender;
pub mod session_folder;
pub mod session_inbox;
pub mod session_limits;
pub(crate) mod session_move_carry;
pub(crate) mod session_move_plan;
pub mod session_queue;
pub mod session_search;
pub(crate) mod session_tail;
pub mod session_turn_cap;
pub mod shutdown;
pub(crate) use crate::slow_notice;
#[cfg(test)]
mod skill_coverage_tests;
pub mod ssh_join;
pub mod stdio;
pub(crate) mod steer_reply;
pub mod task;
pub(crate) mod tools_mcp;
pub mod trigger_chat;
pub mod uniichat_agent;
pub mod uniichat_login;
pub(crate) mod unknown_command;
pub(crate) mod unknown_flag;
pub mod watch;
pub mod who_else;
pub mod worktree;
