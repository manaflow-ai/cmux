//! The `acpmux machine` argument grammar (`PeerCmd`; also `acpmux host`, `hosts`, `peer`) and
//! its pairing tickets, split from `command.rs`.

use clap::Subcommand;
use std::path::PathBuf;

#[derive(Subcommand)]
pub enum PeerCmd {
    /// Add a machine. URL is ws://host:port, wss://…, or ssh://host (tunnel
    /// opened by acpmux; token read from the remote config). Sessions appear
    /// as NAME/session.
    Add {
        name: String,
        /// Default: ssh://NAME, the machine's one daemon as your ssh config reaches it.
        url: Option<String>,
        #[arg(long)]
        token: Option<String>,
    },
    /// List your machines and their connection state.
    Ls,
    /// Each machine's health, asked live: reachable, round trip, disk free,
    /// load, live sessions and build, this machine first. Run it before
    /// remote work and after a request to a machine fails, instead of retrying blind.
    Status {
        /// Only this machine.
        name: Option<String>,
    },
    /// Which machine new work would go to, and why; changes nothing. This machine
    /// and each one you added, weighed by its room (RAM, cores less load, disk,
    /// lane cap) and its role in fleet-registry.json, from the readings the links
    /// already keep: the pick `new --machine auto` and `dispatch --machine auto`
    /// make. `place` still works.
    #[command(name = "pick", alias = "place")]
    Place {
        /// For a build or test suite: only build machines.
        #[arg(long)]
        build: bool,
    },
    /// The lane hosts as one cell (RFD 0181): each one's live sessions against its lane cap,
    /// the hosts past it, and the ones fleet-registry.json keeps work off (held or stopped)
    /// while sessions still run there. Read-only: it reads the fleet listing `acpmux ls` reads
    /// and the registry, and changes nothing.
    Cells,
    /// Whether a machine is dedicated: it runs agents with no per-session
    /// sandbox, the VM is the boundary (vmHost). Claude runs there without the
    /// sandbox only for a session whose caller asked, once the Cloud API said
    /// the caller owns that VM. `off` refuses that on the machine; `on` (the
    /// default off a Mac) stops refusing. Nothing on the machine turns the
    /// boundary on. Shows whether cmux created the VM. `vm-host` still works.
    #[command(name = "dedicated", alias = "vm-host")]
    VmHost {
        /// A machine you added; omit for this machine.
        name: Option<String>,
        /// on or off; omit to show it.
        #[arg(value_parser = ["on", "off"])]
        state: Option<String>,
    },
    /// This machine's load now, as one JSON object: CPU busy share, CPU and
    /// memory pressure (avg60), available memory, swap, OOM kills, free disk,
    /// whether a turn runs here, and a build or test that is running. Reads
    /// only; never starts a daemon. Fields it cannot read are left out.
    /// `--watch`: sample once a second and print one JSON line each time a line
    /// is crossed (memory available under 25% / 10%, an OOM kill, CPU saturated
    /// 5 minutes, disk under 10% or 2 GiB), until stdout closes.
    Load {
        /// Sample once a second and print an event line when a line is crossed.
        #[arg(long)]
        watch: bool,
        #[command(flatten)]
        lines: crate::host_load_watch::Lines,
    },
    /// One walk of the home directory for `load`'s disk split (`disk_usage.rs`); `load` starts
    /// it in the background when the last split is old.
    #[command(name = "disk-walk", hide = true)]
    DiskWalk,
    /// The shadow admission verdict (cmuxterm-hq#7342) for host readings on
    /// stdin: one JSON object, or an array of them, in; the verdict (or an
    /// array of verdicts) out, as JSON. Pure: reads no host and starts no
    /// daemon. A reading with no `now_ms` is judged at this machine's clock.
    /// Nothing is deferred on it; lane-place and placement log it.
    Verdict,
    /// Add one muted line to every live chat on this machine's daemon, such
    /// as the note cmux Cloud adds after it resizes the machine.
    Notice {
        /// The line, one line of at most 300 characters.
        #[arg(long)]
        text: String,
    },
    /// Remove a machine you added.
    Rm { name: String },
    /// Pairing tickets for adding a machine with one pasted line: `new`
    /// mints one, `ls` lists tickets and paired machines, `revoke` ends one.
    #[command(subcommand)]
    Ticket(TicketCmd),
    /// Redeem a pairing ticket from another machine and pair in its role
    /// (the install script runs this with the pasted ticket). The ticket
    /// comes on stdin, one line: `printf '%s\n' TICKET | acpmux machine join`.
    Join {
        /// Deprecated: other users of this machine read argv (ps). Omit it
        /// and pass the ticket on stdin; given here, it warns.
        ticket: Option<String>,
        /// This machine's name on the other one (default: the host name's first label).
        #[arg(long)]
        name: Option<String>,
        /// The other machine's name here (default: its name in the ticket).
        #[arg(long)]
        peer_name: Option<String>,
        /// A daemon-role ticket: the wss:// URL (or ws:// to a loopback host)
        /// the other machine reaches this daemon at.
        #[arg(long)]
        advertise: Option<String>,
        /// Platform origin for a cloud join; defaults to CMUX_PLATFORM_ORIGIN or development.
        #[arg(long, visible_alias = "origin")]
        hub: Option<String>,
        /// Replace an existing cloud machine credential.
        #[arg(long)]
        replace: bool,
        /// Show cloud machine join status without reading stdin.
        #[arg(long)]
        status: bool,
    },
    /// Leave the cloud: revoke this joined machine's credential at the hub
    /// with the credential itself (`tailscale logout`), then remove
    /// `meshRelay`, the credential and the node key here. A hub that cannot
    /// revoke from the machine says to revoke it from your Mac (`cmux machine
    /// revoke NAME`); then `--local-only` removes this machine's state anyway.
    Leave {
        /// Remove the local join state even when the hub did not revoke it.
        #[arg(long)]
        local_only: bool,
    },
    /// Record that the signed-in person signs out of the cmux app, before the app asks the daemon
    /// to leave (no daemon needed): the daemon's next leave or start leaves the join signing in
    /// made for `--user-id`, and nothing of another account's. The cmux app runs it.
    LeaveIntent {
        /// The platform user id of the account signing out.
        #[arg(long)]
        user_id: String,
        /// When the app saw the sign-out (Unix ms; default: now). An intent from before that
        /// account's last sign-in here is stale and not recorded.
        #[arg(long)]
        signed_out_at: Option<u64>,
    },
    /// Enroll this machine on the hub as the signed-in person, the way signing in to the cmux
    /// app does: mints a single-use join token with the person's cmux access token, read from
    /// stdin (never argv), and redeems it here, recorded under `--user-id`. A joined, revoked or
    /// other person's machine, or one joined under no account, is left as it is, and with no
    /// `--user-id` nothing is enrolled. For scripts; a box with no sign-in still uses a pair code
    /// or join line.
    EnrollSelf {
        /// Read the cmux access token from stdin (required).
        #[arg(long, required = true)]
        access_token_stdin: bool,
        /// Platform origin; defaults to CMUX_PLATFORM_ORIGIN or production.
        #[arg(long, visible_alias = "origin")]
        hub: Option<String>,
        /// A DEV build's tag, added to this machine's name.
        #[arg(long)]
        build_tag: Option<String>,
        /// The signed-in person's platform user id, the account the join is recorded under.
        #[arg(long)]
        user_id: Option<String>,
    },
    /// Screen/control consent. From the cmux app (its person proof), or as this Mac's admin
    /// with sudo (`sudo acpmux machine consent grant --control`); a plain shell is refused.
    Consent {
        #[command(subcommand)]
        cmd: ConsentCmd,
    },
    /// The Macs whose cmux app may switch this machine's Control and Screen (pinned in the cmux
    /// app here, after checking their words). `rm` only removes one; nothing here adds one.
    Grantors {
        #[command(subcommand)]
        cmd: GrantorsCmd,
    },
    /// This Mac's Cloud tunnel on the team mesh, through the daemon: attach, detach, rekey.
    /// The daemon takes them only from the cmux app (its person proof), with the person's
    /// cmux access token on stdin; a shell or agent is refused.
    Tunnel {
        #[command(subcommand)]
        cmd: TunnelCmd,
    },
    /// The person's vault on this joined machine: env vars and API keys kept
    /// once for every machine, stored in the OS secret store and given to
    /// every agent here. Never a Claude or Codex subscription login.
    Vault {
        #[command(subcommand)]
        cmd: VaultCmd,
    },
    /// Installed dependencies from the cache, keyed by lockfile: a new Cloud
    /// machine restores node_modules, Cargo's registry and the npm, pnpm and
    /// uv caches instead of installing cold. Never caches credentials files.
    Deps {
        #[command(subcommand)]
        cmd: DepsCmd,
    },
    /// Run VMs for the hub on this host (RFD 0100's host agent): `serve` makes, pauses,
    /// resumes and destroys `cmux-*` VMs through libvirt and enforces each VM's lease here,
    /// with no hosted reaper. Commands come from a local spool (`apply`) until the hub's
    /// command lease is served.
    Hypervisor {
        #[command(subcommand)]
        cmd: HypervisorCmd,
    },
    /// Install this binary and a daemon on a machine over ssh, then add it as a machine here.
    /// A Linux machine also gets acpmux-update.timer, which keeps its daemon on
    /// the newest feat-cmux-next build (`machine self-update`).
    Setup {
        /// ssh target, e.g. cmux-lawrence or user@host
        host: String,
        /// Name here (default: the ssh host's first label).
        #[arg(long)]
        name: Option<String>,
        /// Port the remote daemon listens on (loopback; tunnelled over ssh).
        #[arg(long, default_value_t = 47811)]
        port: u16,
        /// Keep a Linux machine off acpmux-update.timer, which runs `machine
        /// self-update` every 15 minutes (the marker ~/.acpmux/no-auto-update
        /// keeps it off across updates; remove it to turn the timer on).
        #[arg(long)]
        no_auto_update: bool,
        /// Replace the machine's acpmux even when it is built from a newer
        /// commit than this one (the machine refuses that otherwise).
        #[arg(long)]
        allow_downgrade: bool,
        /// Restart the daemon even when an update restarted it in the last
        /// hour. Without it the machine refuses inside that hour, in its own
        /// install step, and nothing is changed.
        #[arg(long)]
        now: bool,
    },
    /// Copy this binary to a machine you added (or every one with --all) and restart
    /// its daemon. The previous binary is kept and put back when the
    /// restarted daemon does not answer with the new build; a daemon under a
    /// hand-written acpmux unit is moved to acpmux.service, agents kept. A
    /// Linux machine gets acpmux-update.timer (`machine self-update`) too.
    Update {
        name: Option<String>,
        #[arg(long)]
        all: bool,
        /// Push DIR/acpmux-<target> instead, the target from the machine's
        /// `uname -sm` (x86_64-unknown-linux-musl, aarch64-unknown-linux-musl,
        /// aarch64-apple-darwin, x86_64-apple-darwin).
        #[arg(long, value_name = "DIR")]
        binary_dir: Option<PathBuf>,
        /// Leave a machine alone while one of its sessions runs a turn or waits
        /// on a permission (but the session this command runs in).
        #[arg(long)]
        if_idle: bool,
        /// Leave a machine alone (`current`) that runs a build of a later day
        /// than the one pushed, or one with local changes: never a move back.
        #[arg(long)]
        keep_newer: bool,
        /// Restart the daemon even when an update (this one, another machine's,
        /// or the machine's own acpmux-update.timer) restarted it in the last
        /// hour. Without it such a machine is left alone (`busy`, reason
        /// `restartWindow`) until the hour is over.
        #[arg(long)]
        now: bool,
        /// Install the pushed binary even when the machine's acpmux is built
        /// from a newer commit. Without it the machine refuses that move back
        /// (`current`, reason `newerInstalled`) in its own install step, so a
        /// push from an older build never undoes its self-update.
        #[arg(long)]
        allow_downgrade: bool,
    },
    /// Hold a machine (a machine name or its ssh host) off `machine update`: the
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
    /// On a Linux machine, bring this machine's own daemon to the newest build
    /// of a channel (what acpmux-update.timer runs every 15 minutes): when
    /// the installed ~/.local/bin/acpmux differs from the channel's, download
    /// this machine's binary, check its sha256, install it and restart the
    /// daemon, agents kept; a daemon that does not come back on it is rolled
    /// back. An update restarts the daemon at most once an hour, whichever
    /// update it is (this one or `machine update` from another machine);
    /// within the hour the machine is left alone until the next run. Prints
    /// the row `machine update` prints for a machine.
    SelfUpdate {
        /// The channel to follow.
        #[arg(long, default_value = "feat-cmux-next")]
        channel: String,
        /// Restart the daemon even when an update restarted it in the last hour.
        #[arg(long)]
        now: bool,
        /// Install the channel's build even when the installed one is built
        /// from a newer commit (pulling a bad channel build back). Without
        /// it the newer installed build is kept.
        #[arg(long)]
        allow_downgrade: bool,
        /// RFD 0060 fast-patch: update now (no wait for the timer or the
        /// restart window), hand over by restart, health read with rollback,
        /// and append one line to ~/.local/state/fast-patch/runs.jsonl
        /// (service acpmux-daemon).
        #[arg(long)]
        fast_patch: bool,
        /// With --fast-patch: the commit expected live; refused when the
        /// channel names another.
        #[arg(long, requires = "fast_patch")]
        commit: Option<String>,
    },
    /// Add a machine in one go: check ssh, install this build, start the
    /// daemon, copy harness profiles and add it here (and, with --reverse,
    /// back). One line per step.
    Enroll {
        /// ssh target, e.g. huge-blue or user@host
        host: String,
        /// Trust and record a previously unknown SSH host key on the first reach check.
        /// A changed key is still refused; later connections use normal host key checks.
        #[arg(long)]
        accept_new_host_key: bool,
        /// Name here (default: the ssh host's first label).
        #[arg(long)]
        name: Option<String>,
        /// A harness profile to copy (repeatable); `local` copies every
        /// profile in this machine's harness folder.
        #[arg(long = "harness", value_name = "ID")]
        harnesses: Vec<String>,
        /// The remote binary to install; another than ~/.local/bin/acpmux
        /// (the app's ~/.local/bin/cmux-tui) gets that path linked to it.
        #[arg(long, default_value = "~/.local/bin/acpmux")]
        remote_binary: String,
        /// Also add this machine on the other one (peer-back). Off
        /// by default: two daemons that list each other relay one another's
        /// sessions both ways.
        #[arg(long)]
        reverse: bool,
    },
    /// The Macs whose cmux app may allow this machine's prompts in a chat it
    /// reaches through its own daemon (`acpmux machine enroll` from the Mac adds
    /// it), and this machine's own app key. `rm` stops a Mac's Allows at once.
    Approvals {
        #[command(subcommand)]
        cmd: Option<ApprovalsCmd>,
    },
    /// Check a machine (a machine name or an ssh host) step by step; --fix
    /// repairs what fails. Without --fix nothing changes. `--here` checks
    /// this machine's one-line join instead (binary, service, daemon,
    /// credential, hub, heartbeat, consent).
    Doctor {
        #[arg(required_unless_present = "here", conflicts_with = "here")]
        target: Option<String>,
        /// Check this machine's one-line join (`cmux machine add`).
        #[arg(long)]
        here: bool,
        #[arg(long)]
        fix: bool,
        /// A harness profile to check (repeatable); `local` checks every
        /// profile in this machine's harness folder.
        #[arg(long = "harness", value_name = "ID")]
        harnesses: Vec<String>,
        #[arg(long, default_value = "~/.local/bin/acpmux")]
        remote_binary: String,
        /// Also check (and with --fix, add) this machine on the other one.
        #[arg(long)]
        reverse: bool,
    },
    /// The tailnet's machines that could be added, marking those already added.
    Candidates {
        /// Also try key-only ssh to each online machine.
        #[arg(long)]
        probe: bool,
    },
    /// A unix socket here that reaches OWNER's lane-gh broker over the held carrier link (RFD
    /// 0127 cut 2) instead of an `ssh -R` forward: one carrier stream per connection, so
    /// `LANE_GH_SOCKET=PATH lane-gh ...` uses it. OWNER serves it once its owner sets
    /// `acpmux config --set lane_gh_broker=PATH`. Runs until stopped.
    BrokerForward {
        /// The machines whose broker to reach (names in the hub's address book), in order of
        /// preference: each connection goes to the first whose broker answered its last
        /// progress check, and fails over before any of its bytes are sent.
        #[arg(value_name = "OWNER", required = true, num_args = 1..)]
        owners: Vec<String>,
        /// Where to listen (a stale socket there is replaced; a served one is left alone).
        #[arg(long, value_name = "PATH")]
        socket: std::path::PathBuf,
    },
    /// This machine's ssh public key: the one line a new machine lists in its
    /// ~/.ssh/authorized_keys, and the command that adds it there. --create makes an
    /// ed25519 key when this machine has none (never over an existing key).
    Key {
        #[arg(long)]
        create: bool,
    },
    /// Claude Code and Codex on MACHINE (a machine name or ssh host): installed, signed
    /// in, and what can be offered. Nothing installs or signs in unless a flag asks.
    Agents {
        #[arg(value_name = "MACHINE")]
        target: String,
        /// Install it there with its vendor's official installer (`harness install`).
        #[arg(long, value_name = "ID", conflicts_with = "login")]
        install: Option<String>,
        /// Sign it in there, in this terminal (`harness login` over ssh -t).
        #[arg(long, value_name = "ID")]
        login: Option<String>,
    },
}

#[derive(Subcommand)]
pub enum VaultCmd {
    /// Pull the vault now with this machine's join credential (the daemon also
    /// pulls every 15 minutes). Values go to the Keychain or Secret Service only.
    Pull,
    /// What this machine holds: names and revisions (never values), the last
    /// pull, the secret store, and whether Claude and Codex are signed in here.
    Status,
    /// Remove this machine's vault env values and its vault state. The daemon
    /// pulls again while the vault is shared with this machine.
    Forget,
    /// Keep a key an agent made on this machine, with no sign-in or click: the
    /// value comes piped on stdin (never argv) and goes to the Keychain or
    /// Secret Service only. Agents started from then on get the placeholder
    /// `cmux-secret://NAME`, which the egress proxy fills only in HTTPS
    /// requests to the --host patterns. Example:
    /// `mint-token | acpmux machine vault keep DEPLOY_TOKEN --host api.example.com`.
    Keep {
        /// The env name agents get, like DEPLOY_TOKEN.
        name: String,
        /// Where the key may be sent: a host or `*.domain` (repeatable).
        #[arg(long = "host", value_name = "H")]
        hosts: Vec<String>,
        /// Give agents the value itself instead (weaker: agents can read it).
        #[arg(long, conflicts_with = "hosts")]
        env: bool,
    },
    /// Remove a kept key (`keep`) from this machine.
    Drop { name: String },
    /// List every secret this user's processes and files can reach, by name and
    /// path only (never a value), and exit 1 when anything but the owner's
    /// harness login or this machine's own identity is reachable (exit 2: the
    /// audit could not see everything). A Cloud chat's VM runs it after a move.
    Audit,
}

/// Where `machine hypervisor` keeps its state and talks to libvirt.
#[derive(clap::Args, Clone, Debug)]
pub struct HypervisorOpts {
    /// State folder: leases.json, status.json, the command spool and the VM disks
    /// (default: ~/.acpmux/hypervisor).
    #[arg(long, value_name = "DIR")]
    pub state_dir: Option<PathBuf>,
    /// libvirt connection URI (`virsh -c`), such as qemu:///system.
    #[arg(long, value_name = "URI")]
    pub connect: Option<String>,
    /// What a slot is: a KVM guest (libvirt), or a pod on this host (a systemd slice
    /// whose init runs in bwrap), for hosts that cannot run VMs.
    #[arg(long, value_enum, default_value_t = HypervisorDriverKind::Libvirt)]
    pub driver: HypervisorDriverKind,
    /// With --driver pods: the folder of pod roots (default: <state dir>/pods).
    #[arg(long, value_name = "DIR")]
    pub pods_dir: Option<PathBuf>,
    /// With --driver pods: the program each pod boots, HOME at its root (default: sleep
    /// infinity). For a guest, `acpmux` with `--pod-init-arg daemon`. With `serve --source
    /// hub` each new pod's init also gets a one-time join token the host minted for its slot
    /// in CMUX_JOIN_TOKEN and its hub in CMUX_JOIN_HUB: an init `sh -c 'printf "%s\n"
    /// "$CMUX_JOIN_TOKEN" | acpmux machine join --hub "$CMUX_JOIN_HUB"; unset
    /// CMUX_JOIN_TOKEN; exec acpmux daemon'` joins the pod as its own machine.
    #[arg(long, value_name = "PROGRAM")]
    pub pod_init: Option<String>,
    /// An argument for --pod-init; repeat for more.
    #[arg(long = "pod-init-arg", value_name = "ARG", allow_hyphen_values = true)]
    pub pod_init_args: Vec<String>,
    /// With --driver pods: a variable of serve's own environment to hand each pod's init,
    /// by name, so its value never shows in an argv (a model token); repeat for more.
    #[arg(long = "pod-env", value_name = "NAME")]
    pub pod_env: Vec<String>,
    /// With --driver pods: a host path every pod sees read-only at its own path, such as a
    /// harness installed under a home (`~/.local/share/claude`); repeat for more.
    #[arg(long = "pod-bind", value_name = "PATH")]
    pub pod_bind: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub enum HypervisorSourceKind {
    Spool,
    Hub,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub enum HypervisorDriverKind {
    Libvirt,
    Pods,
}

#[derive(Subcommand)]
pub enum HypervisorCmd {
    /// Apply queued commands and enforce leases, every --interval-secs: a VM past its
    /// delete-after is destroyed; one past its max run or idle time, or whose lease the hub
    /// stopped renewing, or with no lease at all, is paused to disk, never deleted.
    Serve {
        #[command(flatten)]
        opts: HypervisorOpts,
        /// The qcow2 base image each VM's overlay disk is backed by.
        #[arg(long, value_name = "FILE")]
        base_image: Option<PathBuf>,
        /// libvirt network the VMs attach to.
        #[arg(long, default_value = "default")]
        network: String,
        /// Domain XML template ({{name}}, {{vcpus}}, {{memory_mib}}, {{disk}},
        /// {{network}}, {{seed_disk}}); a KVM default when omitted.
        #[arg(long, value_name = "FILE")]
        template: Option<PathBuf>,
        /// Seconds between passes.
        #[arg(long, default_value_t = 5)]
        interval_secs: u64,
        /// One pass, then exit.
        #[arg(long)]
        once: bool,
        /// Where commands come from: the local spool `apply` writes, or the hub's command
        /// lease for this joined machine (`acpmux machine join` first; its own credential).
        #[arg(long, value_enum, default_value_t = HypervisorSourceKind::Spool)]
        source: HypervisorSourceKind,
        /// With --source hub: the most commands one lease takes (1 to 32).
        #[arg(long, default_value_t = 8)]
        lease_max: u32,
    },
    /// Queue one command for `serve`, as JSON on stdin: {"verb":"create","slot":"a1",
    /// "spec":{"vcpus":2,"memoryMib":4096},"lease":{"deleteAfterSecs":86400}}; verbs are
    /// create, pause, resume, destroy, renew, touch and end.
    Apply {
        #[command(flatten)]
        opts: HypervisorOpts,
        /// The command's id (default: the time and the slot).
        #[arg(long)]
        id: Option<String>,
    },
    /// List this host's cmux VMs, their state and lease.
    Ls {
        #[command(flatten)]
        opts: HypervisorOpts,
    },
}

#[derive(Subcommand)]
pub enum DepsCmd {
    /// Restore each project's dependencies in DIR (bun, npm, pnpm, yarn, Cargo,
    /// uv) from this machine's cache, run its normal install, and after a cold
    /// install upload an archive for the next machine.
    Warm {
        /// The project folder (default: the current folder).
        dir: Option<std::path::PathBuf>,
        /// Do not upload an archive after a cold install.
        #[arg(long)]
        no_upload: bool,
        /// Only restore; do not run the install.
        #[arg(long)]
        no_install: bool,
        /// Do nothing unless this machine is joined (what runs after a seed).
        #[arg(long)]
        if_joined: bool,
        /// Skip a project whose dependencies are already installed (its
        /// `node_modules` or `.venv`), so an install never replaces a tree in use.
        #[arg(long)]
        if_missing: bool,
        /// Pack and upload after a cold install before returning, instead of
        /// in a detached `machine deps upload`.
        #[arg(long)]
        upload_now: bool,
    },
    /// Pack a cache folder and upload it under KEY (what `warm` starts
    /// detached after a cold install).
    #[command(hide = true)]
    Upload {
        #[arg(long)]
        key: String,
        #[arg(long)]
        root: std::path::PathBuf,
        #[arg(long = "include", required = true)]
        include: Vec<std::path::PathBuf>,
        /// zstd or gzip.
        #[arg(long)]
        codec: String,
        /// The cold install the archive saves, stored beside it.
        #[arg(long, default_value_t = 0)]
        cold_ms: u64,
    },
    /// Wait until no background upload (`warm` after a cold install) is running.
    Wait,
    /// Print each project's cache key and what its archive holds, without asking the hub.
    Key {
        /// The project folder (default: the current folder).
        dir: Option<std::path::PathBuf>,
    },
}

#[derive(Subcommand)]
pub enum TunnelCmd {
    /// Put this Mac in its team's WireGuard peer map.
    Attach {
        /// The team network id; it must be this Mac's own team.
        #[arg(long, value_name = "ID")]
        network: Option<String>,
    },
    /// Take this Mac out of its team's peer map until the next attach.
    Detach {
        /// The team network id; it must be this Mac's own team.
        #[arg(long, value_name = "ID")]
        network: Option<String>,
    },
    /// Give this Mac a new WireGuard key (in the process that holds the key).
    Rekey,
}

#[derive(Subcommand)]
pub enum ConsentCmd {
    /// Grant screen, control or signed-in-machines consent (exactly one). Under sudo it is set
    /// here as this Mac's admin; otherwise the daemon takes it only from the cmux app.
    #[command(group(clap::ArgGroup::new("surface").required(true).args(["screen", "control", "signed_in_machines"])))]
    Grant {
        /// Screen recording.
        #[arg(long)]
        screen: bool,
        /// Keyboard and mouse control.
        #[arg(long)]
        control: bool,
        /// Control from this person's other machines signed in to the same account.
        #[arg(long)]
        signed_in_machines: bool,
    },
    /// Revoke screen, control or signed-in-machines consent (exactly one), the same ways.
    #[command(group(clap::ArgGroup::new("surface").required(true).args(["screen", "control", "signed_in_machines"])))]
    Revoke {
        /// Screen recording.
        #[arg(long)]
        screen: bool,
        /// Keyboard and mouse control.
        #[arg(long)]
        control: bool,
        /// Control from this person's other machines signed in to the same account.
        #[arg(long)]
        signed_in_machines: bool,
    },
}

#[derive(Subcommand)]
pub enum GrantorsCmd {
    /// The pinned Macs (id, name, account, key words) and the pending ask.
    List,
    /// Stop a Mac's grants here at once, and drop its pending ask.
    Rm {
        /// The Mac's grantor id (`mac-` and 16 hex digits).
        id: String,
    },
}

#[derive(Subcommand)]
pub enum ApprovalsCmd {
    /// Let a Mac's cmux app allow this machine's prompts.
    Add {
        /// The Mac's approver id (its app gives it; `machine approvals` on the Mac shows it).
        #[arg(long)]
        id: String,
        /// Its public key: a 65-byte uncompressed P-256 point as hex.
        #[arg(long)]
        key: String,
        /// A name to show.
        #[arg(long)]
        name: Option<String>,
    },
    /// Stop a Mac's Allows here, at once (`rm standing-grant` ends the standing grant).
    Rm { id: String },
    /// Record a standing pre-grant on this machine: a key of this user's own, enrolled here, with
    /// which `acpmux allow SESSION --standing-grant` signs a one-time allow of a plain tool ask
    /// (never a lasting allow, a plan, a mode, a policy or a rule). Keeps the key already there.
    Grant,
    /// From this Mac: let its cmux app allow the prompts of MACHINE (a machine name
    /// or ssh host), over ssh. The approvals step of `machine enroll`, alone.
    Enroll {
        #[arg(value_name = "MACHINE")]
        peer: String,
    },
    /// From this Mac: stop its cmux app's Allows on MACHINE, at once.
    Unenroll {
        #[arg(value_name = "MACHINE")]
        peer: String,
    },
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
        /// The machine's id or name (`acpmux machine ticket ls`).
        id: String,
        /// on or off.
        #[arg(value_parser = ["on", "off"])]
        state: String,
    },
}
