//! The `acpmux host` argument grammar (`PeerCmd`, also `acpmux peer`) and
//! its pairing tickets, split from `command.rs`.

use clap::Subcommand;
use std::path::PathBuf;

#[derive(Subcommand)]
pub enum PeerCmd {
    /// Add a peer. URL is ws://host:port, wss://…, or ssh://host (tunnel
    /// opened by acpmux; token read from the remote config). Sessions appear
    /// as NAME/session.
    Add {
        name: String,
        /// Default: ssh://NAME, the machine's one daemon as your ssh config reaches it.
        url: Option<String>,
        #[arg(long)]
        token: Option<String>,
    },
    /// List peers and their connection state.
    Ls,
    /// Each peer's health, asked live: reachable, round trip, disk free,
    /// load, live sessions and build, this machine first. Run it before
    /// remote work and after a peer request fails, instead of retrying blind.
    Status {
        /// Only this peer.
        name: Option<String>,
    },
    /// Where new work should go: this machine and each peer weighed by its
    /// room (RAM, cores less load, disk, lane cap) and its role in
    /// fleet-registry.json, from the readings the links already keep. The
    /// pick `new --host auto` and `dispatch --host auto` make, with why.
    Place {
        /// For a build or test suite: only build hosts.
        #[arg(long)]
        build: bool,
    },
    /// Whether a machine is a dedicated agent VM (vmHost): Claude runs there
    /// without the sandbox and your own machine's sessions start approve-all,
    /// the VM being the boundary. On by default on a VM cmux created, never
    /// on a personal or SSH-added machine (`on` is refused there). Applies to
    /// new sessions at once, with no restart.
    VmHost {
        /// A peer; omit for this machine.
        name: Option<String>,
        /// on or off; omit to show it.
        #[arg(value_parser = ["on", "off"])]
        state: Option<String>,
    },
    /// Remove a peer.
    Rm { name: String },
    /// Pairing tickets for adding a machine with one pasted line: `new`
    /// mints one, `ls` lists tickets and paired machines, `revoke` ends one.
    #[command(subcommand)]
    Ticket(TicketCmd),
    /// Redeem a pairing ticket from another machine and pair in its role
    /// (the install script runs this with the pasted ticket).
    Join {
        ticket: String,
        /// This machine's name on the other one (default: the host name's first label).
        #[arg(long)]
        name: Option<String>,
        /// The other machine's peer name here (default: its name in the ticket).
        #[arg(long)]
        peer_name: Option<String>,
        /// A daemon-role ticket: the wss:// URL (or ws:// to a loopback host)
        /// the other machine reaches this daemon at.
        #[arg(long)]
        advertise: Option<String>,
    },
    /// Install this binary and a daemon on a machine over ssh, then add it as a peer.
    /// A Linux host also gets acpmux-update.timer, which keeps its daemon on
    /// the newest feat-cmux-next build (`host self-update`).
    Setup {
        /// ssh target, e.g. cmux-lawrence or user@host
        host: String,
        /// Peer name (default: the host's first label).
        #[arg(long)]
        name: Option<String>,
        /// Port the remote daemon listens on (loopback; tunnelled over ssh).
        #[arg(long, default_value_t = 47811)]
        port: u16,
        /// Keep a Linux host off acpmux-update.timer, which runs `host
        /// self-update` every 15 minutes (the marker ~/.acpmux/no-auto-update
        /// keeps it off across updates; remove it to turn the timer on).
        #[arg(long)]
        no_auto_update: bool,
    },
    /// Copy this binary to an ssh peer (or every one with --all) and restart
    /// its daemon. The previous binary is kept and put back when the
    /// restarted daemon does not answer with the new build; a daemon under a
    /// hand-written acpmux unit is moved to acpmux.service, agents kept. A
    /// Linux peer gets acpmux-update.timer (`host self-update`) too.
    Update {
        name: Option<String>,
        #[arg(long)]
        all: bool,
        /// Push DIR/acpmux-<target> instead, the target from the peer's
        /// `uname -sm` (x86_64-unknown-linux-musl, aarch64-unknown-linux-musl,
        /// aarch64-apple-darwin, x86_64-apple-darwin).
        #[arg(long, value_name = "DIR")]
        binary_dir: Option<PathBuf>,
        /// Leave a peer alone while one of its sessions runs a turn or waits
        /// on a permission (but the session this command runs in).
        #[arg(long)]
        if_idle: bool,
        /// Leave a peer alone (`current`) that runs a build of a later day
        /// than the one pushed, or one with local changes: never a move back.
        #[arg(long)]
        keep_newer: bool,
    },
    /// Hold a machine (a peer name or its ssh host) off `host update`: the
    /// update, `--all` and the app's own update queue leave it alone (`held`)
    /// and never reach it, so its daemon is never restarted. For a machine
    /// that is not yours to update now, such as one reserved for someone
    /// else. With no NAME, list the holds (~/.acpmux/update-holds.json).
    Hold {
        name: Option<String>,
        /// Why, shown in the update's row.
        #[arg(long, requires = "name")]
        reason: Option<String>,
        /// When the hold ends by itself (RFC 3339, 2026-10-28T23:59:59Z).
        #[arg(long, requires = "name")]
        until: Option<String>,
        /// End the hold.
        #[arg(long, requires = "name", conflicts_with_all = ["reason", "until"])]
        release: bool,
    },
    /// On a Linux host, bring this machine's own daemon to the newest build
    /// of a channel (what acpmux-update.timer runs every 15 minutes): when
    /// the installed ~/.local/bin/acpmux differs from the channel's, download
    /// this host's binary, check its sha256, install it and restart the
    /// daemon, agents kept; a daemon that does not come back on it is rolled
    /// back. Prints the row `host update` prints for a peer.
    SelfUpdate {
        /// The channel to follow.
        #[arg(long, default_value = "feat-cmux-next")]
        channel: String,
    },
    /// Add a machine in one go: check ssh, install this build, start the
    /// daemon, copy harness profiles and peer to it (and, with --reverse,
    /// back). One line per step.
    Enroll {
        /// ssh target, e.g. huge-blue or user@host
        host: String,
        /// Peer name (default: the host's first label).
        #[arg(long)]
        name: Option<String>,
        /// A harness profile to copy (repeatable).
        #[arg(long = "harness", value_name = "ID")]
        harnesses: Vec<String>,
        /// The remote binary to install; another than ~/.local/bin/acpmux
        /// (the app's ~/.local/bin/cmux-tui) gets that path linked to it.
        #[arg(long, default_value = "~/.local/bin/acpmux")]
        remote_binary: String,
        /// Also register this machine as a peer on the host (peer-back). Off
        /// by default: two daemons that list each other relay one another's
        /// sessions both ways.
        #[arg(long)]
        reverse: bool,
    },
    /// The Macs whose cmux app may allow this machine's prompts in a chat it
    /// reaches through its own daemon (`acpmux host enroll` from the Mac adds
    /// it), and this machine's own app key. `rm` stops a Mac's Allows at once.
    Approvals {
        #[command(subcommand)]
        cmd: Option<ApprovalsCmd>,
    },
    /// Check a machine (a peer name or an ssh host) step by step; --fix
    /// repairs what fails. Without --fix nothing changes.
    Doctor {
        target: String,
        #[arg(long)]
        fix: bool,
        /// A harness profile to check (repeatable).
        #[arg(long = "harness", value_name = "ID")]
        harnesses: Vec<String>,
        #[arg(long, default_value = "~/.local/bin/acpmux")]
        remote_binary: String,
        /// Also check (and with --fix, add) this machine as a peer on the host.
        #[arg(long)]
        reverse: bool,
    },
    /// The tailnet's machines that could be added, marking those already peers.
    Candidates {
        /// Also try key-only ssh to each online machine.
        #[arg(long)]
        probe: bool,
    },
}

#[derive(Subcommand)]
pub enum ApprovalsCmd {
    /// Let a Mac's cmux app allow this machine's prompts.
    Add {
        /// The Mac's approver id (its app gives it; `host approvals` on the Mac shows it).
        #[arg(long)]
        id: String,
        /// Its public key: a 65-byte uncompressed P-256 point as hex.
        #[arg(long)]
        key: String,
        /// A name to show.
        #[arg(long)]
        name: Option<String>,
    },
    /// Stop a Mac's Allows here, at once.
    Rm { id: String },
    /// From this Mac: let its cmux app allow the prompts of PEER (a peer name
    /// or ssh host), over ssh. The approvals step of `host enroll`, alone.
    Enroll { peer: String },
    /// From this Mac: stop its cmux app's Allows on PEER, at once.
    Unenroll { peer: String },
}

#[derive(Subcommand)]
pub enum TicketCmd {
    /// Mint a single-use ticket; prints the line to run on the new machine.
    New {
        /// daemon (this machine drives the new one), client (the new one
        /// drives this one) or read-only (the new one only watches).
        #[arg(long, default_value = "client")]
        role: String,
        /// How long the ticket lives: 900, 15m or 2h (at most 24h).
        #[arg(long, default_value = "15m")]
        ttl: String,
        /// The wss:// URL the new machine dials (default: this daemon's
        /// listener, when it listens on loopback).
        #[arg(long)]
        url: Option<String>,
        /// A note shown in `ticket ls`.
        #[arg(long)]
        label: Option<String>,
    },
    /// Tickets and paired machines (no secrets).
    #[command(alias = "list")]
    Ls,
    /// Revoke a ticket, or a paired machine by id or name; its open connections close at once.
    Revoke { id: String },
    /// Let a paired client machine run chats in Full access (on), or not
    /// (off, the default): the agent edits files and runs commands on this
    /// machine without asking. On needs the person (the cmux app's Settings);
    /// off takes effect at once.
    FullAccess {
        /// The machine's id or name (`cmux host ticket ls`).
        id: String,
        /// on or off.
        #[arg(value_parser = ["on", "off"])]
        state: String,
    },
}
