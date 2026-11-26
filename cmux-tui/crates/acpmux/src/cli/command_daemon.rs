//! The `acpmux daemon` argument grammar (`DaemonCmd`) and its retention pass's flags, split
//! from `command.rs`.

use clap::{Args, Subcommand};
use std::path::PathBuf;

#[derive(Subcommand)]
pub enum DaemonCmd {
    /// Run the daemon in the foreground.
    Run {
        /// Also serve WebSocket clients, e.g. 127.0.0.1:47811
        #[arg(long)]
        listen: Option<String>,
        /// Bearer token WebSocket clients must present.
        #[arg(long)]
        token: Option<String>,
        /// Allow a network (non-loopback) --listen or websocket.listen address.
        /// The listener speaks plain ws://, so its token crosses that network
        /// in clear; prefer loopback reached through ssh or a TLS proxy.
        #[arg(long)]
        insecure_network_listen: bool,
        /// Keep everything in memory. Nothing survives restart.
        #[arg(long)]
        memory: bool,
        /// Log level filter, e.g. debug or acpmux=trace
        #[arg(long, default_value = "info")]
        log: String,
        /// Write one JSON line ({"ready":true,"pid","socket","listen","webUrl"}) to this
        /// inherited file descriptor once the socket and listen address are bound.
        #[arg(long)]
        ready_fd: Option<i32>,
        /// Read this launch's person key (64 hex characters) from this
        /// inherited file descriptor, then close it. Only the cmux app passes
        /// it, and only an unsigned daemon takes it (`hub/person.rs`).
        #[arg(long)]
        person_key_fd: Option<i32>,
        /// A loopback page dev server origin the web listener also accepts
        /// (`http://127.0.0.1:<port>` or `http://localhost:<port>`). Only a
        /// Debug app passes it, for its agent pane dev server; it is not saved.
        #[arg(long = "allow-dev-origin")]
        allow_dev_origin: Vec<String>,
        /// A development launch: `--allow-dev-origin` is honored only with it
        /// (or in a debug build). Release launchers never pass it.
        #[arg(long)]
        dev: bool,
        /// This daemon is the home's supervised owner (the systemd unit passes it): when another
        /// daemon of this home holds the lock and serves this same socket, ask it to hand over
        /// (its agents keep running for this daemon to adopt) instead of exiting. A lock refusal
        /// then exits 1, never 75, so the unit keeps retrying.
        #[arg(long)]
        take_over: bool,
    },
    /// Daemon status, hosts, and the web URL (without its token).
    Status {
        /// Print the web URL with its bearer token (`--json` always has it in `webUrl`).
        #[arg(long)]
        show_token: bool,
    },
    /// Start the daemon unless one runs, wait until it accepts clients, and print its status.
    Start {
        /// Read this launch's person key (64 hex characters, one line) from
        /// this descriptor (0: stdin) and hand it to the daemon it starts,
        /// once that daemon is not dumpable. Only the cmux app's own ssh exec
        /// or VM provisioning passes it; refused while a daemon runs.
        #[arg(long)]
        person_key_fd: Option<i32>,
        /// Print the web URL with its bearer token (`--json` always has it in `webUrl`).
        #[arg(long)]
        show_token: bool,
    },
    /// Give the daemon that runs the person key (64 hex characters, one line) from this
    /// descriptor, and print its status. Only the VM provisioning exec runs it, as root: the
    /// daemon takes the key only from a root peer, and only when it is not root itself
    /// (`daemon/provision.rs`). It never starts a daemon.
    #[command(hide = true)]
    Enroll {
        /// The descriptor to read the key from (0: stdin).
        #[arg(long)]
        person_key_fd: i32,
    },
    /// The busiest callers of the running daemon over a recent window (at most the last 10
    /// minutes): requests, bytes in and out, and each caller's client name, origin, pid and
    /// session, so a client that asks too often can be found. A daemon without per-caller stats
    /// shows its list replies by client instead.
    Stats {
        /// One row per caller (with its busiest methods) or per method.
        #[arg(long, value_enum, default_value_t = crate::cli::daemon_stats::By::Caller)]
        by: crate::cli::daemon_stats::By,
        /// The window, e.g. 60s, 5m or 10m (at most 10m).
        #[arg(long, default_value = "60s")]
        since: String,
        /// How many rows.
        #[arg(long, default_value_t = 20)]
        top: usize,
    },
    /// The felt-latency histograms of the running daemon (the net graph): p50, p90 and p99 of what a
    /// person feels (a prompt's send to ack, a typed key's echo) over the last minute and since
    /// start. Numbers and names only.
    Felt,
    /// Tell the stable tailnet node's front where a workspace runs now: one placement message as
    /// JSON (`{"kind":"moved","workspace":"default","placement":{"ssh":"10.0.0.5:22"}}`; kinds
    /// set, moved, removed). Open connections keep their target; new ones go to the new place.
    Placement {
        /// The placement message (JSON).
        message: String,
    },
    /// Restart the daemon, preserving hosted sessions so they resume on startup.
    Restart,
    /// Clear what dead daemons left: for the shared home and each per-build home, the socket and
    /// pid file of a daemon whose lock nobody holds and whose pid is gone. A running daemon is
    /// never stopped from outside: one whose executable is gone stops itself once unused for 5
    /// minutes. A dry run that lists every home, what it would clear and why each other is left,
    /// unless --apply. A daemon on the person's own homes runs this by itself every 10 minutes
    /// (`ACPMUX_DAEMON_PRUNE=0` turns that and the retired stop off).
    Prune {
        /// Stop the retired daemons (SIGTERM: their hosted agents keep running for the next
        /// daemon of that home), each logged with pid, build, age and reason.
        #[arg(long)]
        apply: bool,
    },
    /// The service that keeps this machine's daemon running: the LaunchAgent on macOS, the
    /// user systemd unit on Linux (the files `host setup` writes on an ssh host).
    Service {
        #[command(subcommand)]
        action: crate::cli::daemon_service::ServiceAction,
    },
    /// Stop the daemon. Hosted agents keep running for the next daemon to
    /// adopt (a restart or an update); pooled hosts end. `--end-agents` ends
    /// every agent process too, agent hosts included, returns once they all
    /// exited, and fails naming any host left.
    #[command(visible_alias = "stop", alias = "kill-server")]
    Shutdown {
        /// Accepted for callers of older builds, where a plain shutdown ended
        /// the agents; hosted agents keep running anyway.
        #[arg(long, hide = true, conflicts_with = "end_agents")]
        keep_agents: bool,
        /// Signal service restart to clients while stopping for an external updater.
        #[arg(long, conflicts_with = "end_agents")]
        restart: bool,
        /// End every agent process too, hosted agents and their hosts included.
        #[arg(long)]
        end_agents: bool,
    },
    /// Print the config path and contents (without its tokens).
    Config {
        /// Print the bearer tokens too (`--json` always has them).
        #[arg(long)]
        show_token: bool,
        /// Set a host-wide session resource setting as KEY=VALUE.
        #[arg(long, value_name = "KEY=VALUE")]
        set: Option<String>,
    },
    /// Show configured harnesses with their family and defaults.
    Harnesses,
    /// Reload catalog configuration without stopping sessions.
    Reload,
    /// Compact the event logs of chats closed for longer than `store.closedLogDays` (default
    /// 14): their raw harness lines and long tool output go, their messages stay.
    Retention(RetentionArgs),
    /// Print the RPC schema (methods, notifications, types, exit codes) as JSON.
    Schema,
    /// Every model id each harness declares or reports (`provider/model` for OpenCode and pi).
    Models {
        /// Forget the reported catalogs and probe every harness again now.
        #[arg(long)]
        refresh: bool,
    },
}

#[derive(Args, Debug, Clone, PartialEq, Eq)]
pub struct RetentionArgs {
    /// Only report the chats and bytes a pass would compact; change nothing.
    #[arg(long)]
    pub dry_run: bool,
    /// Keep every old log segment under this folder (`<folder>/<chat id>/<pass>/events/`).
    #[arg(long)]
    pub archive: Option<PathBuf>,
    /// Chats closed for longer than this many days, instead of the setting.
    #[arg(long)]
    pub older_than_days: Option<u32>,
    /// One chat only (name or id).
    #[arg(long)]
    pub only: Option<String>,
    /// Drop only the records no reader takes back (a resume's replayed history, thinking ticks,
    /// hook callbacks; a Codex resume answer's thread), from any chat nothing uses now, open or
    /// closed. Each log must read back the same chat rows before it is replaced; with --archive
    /// the old segments stay there.
    #[arg(long)]
    pub unread_only: bool,
}
