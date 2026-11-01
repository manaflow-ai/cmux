//! An OptChat Chief for cmux-next Home. It keeps the brain-host contract of
//! `mux/host` (the app starts it through `CMUX_NEXT_MUX_HOST`, it holds the
//! same kernel lock, talks to the conversation owner as `agent_mux` and to
//! acpmux), and replaces the long-lived `mux` session with Victor Taelin's
//! OptChat turn loop: every turn is a fresh acpmux session that reads the
//! OptChat view, and everything it does is logged into the memory.
//! Section numbers in comments refer to the OptChat specification.

pub mod acpmux;
pub mod acpmux_daemon;
pub mod acpmux_peer;
pub mod agent_chat;
pub mod agent_keys;
pub mod agent_memory;
pub mod agents;
pub mod approval;
pub mod auto_resume;
pub mod backup;
pub mod brain;
pub mod browse;
pub mod chief_profile;
pub mod chief_settings;
pub mod claude_import;
pub mod cli;
pub mod cloud;
pub mod cloud_vms;
pub mod cloud_workspace;
pub mod cmux_env;
pub mod code_signature;
pub mod codex_home;
pub mod compactor;
pub mod daemon;
pub mod draft;
pub mod effort;
pub mod engine;
pub mod fleet_wait;
pub mod fold;
pub mod github;
pub mod harness_gate;
pub mod home_view;
pub mod host;
pub mod inspect;
pub mod link_preview;
pub mod lock;
pub mod log;
pub mod mcp;
pub mod membership;
pub mod memory_cli;
pub mod memory_sync;
pub mod memory_sync_state;
pub mod migrate;
pub mod migrate_cloud;
pub mod migrate_reach;
pub mod native;
pub mod pacing;
pub mod paths;
pub mod peer_chiefs;
pub mod persist;
pub mod prompt;
pub mod remember;
pub mod reply_links;
pub mod report;
pub mod rpc;
pub mod run;
pub mod screen_share;
pub mod session_dir;
pub mod settle_status;
pub mod show;
pub mod single_flight;
pub mod skills;
pub mod spawn_route;
pub mod state;
pub mod sub_watch;
pub mod subagents;
pub mod toolpacks;
pub mod tools;
pub mod trace;
pub mod turn;
pub mod turn_caller;
pub mod turn_retention;
pub mod turn_user_extras;
pub mod update_watch;
pub mod usage;
pub mod version_tool;
pub mod voice;
pub mod wake;
pub mod watch;
pub mod workspaces;
