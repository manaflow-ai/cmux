//! The `acpmux` argument grammar. `entry` parses it; `run` executes it.

use clap::{Args, Parser, Subcommand};
use std::path::PathBuf;

pub use crate::cli::command_host::{PeerCmd, TicketCmd};
pub use crate::cli::task::BriefsCmd;

#[derive(Parser)]
#[command(name = "acpmux", version = crate::hub::version_line(), about = "tmux for coding-agent harnesses: Claude Code, Codex, OpenCode, pi, Gemini", long_about = None, after_help = "Agents: `acpmux guide` (also --guide, --skill) prints the full guide for driving acpmux from a script or another agent.")]
pub struct Cli {
    /// Print raw JSON instead of text.
    #[arg(long, global = true)]
    pub json: bool,
    /// Blank read-tool payloads in event output, keeping the message shape.
    #[arg(long, global = true)]
    pub suppress_reads: bool,
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Subcommand)]
pub enum Command {
    /// Own one dedicated Codex sign-in over private stdin/stdout pipes.
    #[cfg(unix)]
    #[command(hide = true)]
    CodexAuthBroker {
        #[arg(long)]
        home: PathBuf,
        #[arg(long)]
        codex: PathBuf,
    },
    /// `gh` for an agent on a machine the person added: the GitHub broker's actions, run by the
    /// Mac that lends this machine its login (`cli/gh_shim.rs`).
    #[command(hide = true, disable_help_flag = true)]
    Gh {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// Send a local brief to another harness on a machine (or the least-loaded
    /// allowed machine with `--machine auto`) and record its identity.
    Dispatch(DispatchArgs),
    /// Task briefs: list, steer and report work tracked by the daemon.
    #[command(subcommand)]
    Briefs(BriefsCmd),
    /// Give a session here a task, end one with its result in one call, list a chat's tasks.
    #[command(subcommand)]
    Task(crate::cli::task::TaskCmd),
    /// Find the session an agent link (a PR footer's cmux.com/deeplink/agent?... or
    /// cmux://agent/...), session id, harness session id or name names, here or on a peer, and
    /// print its host, ids, harness, model, folder, lane, pull requests, last turn and link.
    #[command(alias = "find")]
    Resolve {
        /// The link, an id, `HOST/NAME`, a name, a bead id, or `@` for this session.
        query: String,
    },
    /// Link a session to the tracker beads it works on (`bd` ids), unlink them, list them.
    #[command(subcommand)]
    Bead(crate::cli::beads::BeadCmd),
    /// Create a session and optionally send a first prompt. `run` is the
    /// same with --quiet: it prints only the final reply. With --worktree,
    /// --prompt-file, --report-to and --group it starts an agent on a task
    /// in one step; running it again reuses everything and sends nothing.
    #[command(alias = "new-session", alias = "run", alias = "exec")]
    New(Box<NewArgs>),
    /// Block until a session resolves: its turn ends or it needs a permission
    /// answer. Returns on the first one unless --all. Exit 0 when a turn
    /// ended, 2 when a permission is waiting, 3 on timeout.
    #[command(alias = "wait-for")]
    Wait {
        /// Session names or ids. Every running session on every host when omitted.
        sessions: Vec<String>,
        /// Give up after this many seconds.
        #[arg(long)]
        timeout: Option<u64>,
        /// Wait for every named session, not just the first to resolve.
        #[arg(long)]
        all: bool,
        #[arg(long, hide = true)]
        any: bool,
        /// Also print each finished session's last reply.
        #[arg(long, short)]
        print: bool,
        /// States to wait for: ready, permission, closed, done, running. Default: ready or permission.
        #[arg(long = "until", value_delimiter = ',')]
        until: Vec<String>,
        /// Resolve when the transcript contains this text.
        #[arg(long = "match", conflicts_with = "regex")]
        match_text: Option<String>,
        /// Resolve when a transcript line matches this regular expression.
        #[arg(long)]
        regex: Option<String>,
        /// Send a terminal notification (OSC 9/99) when it resolves.
        #[arg(long)]
        notify: bool,
    },
    /// Get a session by name, or create it: idempotent for scripts.
    Ensure {
        name: String,
        /// HARNESS[/MODEL]: a family or profile, optionally with a model (`claude/opus`, `opencode/zai/glm-5.1`).
        #[arg(long, short)]
        model: Option<String>,
        /// A preset from `acpmux preset`: harness plus model, effort, policy, env.
        #[arg(long, short)]
        preset: Option<String>,
        /// Create on this machine when missing (`--host` still works).
        #[arg(long = "machine", alias = "host", value_name = "MACHINE")]
        host: Option<String>,
        #[arg(long)]
        cwd: Option<PathBuf>,
        #[arg(long)]
        policy: Option<String>,
        #[arg(long, short)]
        effort: Option<String>,
        /// Label the session when it is created (repeatable `key=value`).
        #[arg(long = "tag", value_name = "K=V")]
        tags: Vec<String>,
        /// Create it on exactly the harness SESSION ran (profile, preset, model, effort).
        #[arg(long, value_name = "SESSION", conflicts_with_all = ["model", "preset", "effort"])]
        harness_from: Option<String>,
    },
    /// Continue a session's work on another harness: prepare a reviewed
    /// first message for a new session there, then start or discard it.
    Continue(crate::cli::handoff::ContinueArgs),
    /// Retry a session's failed last turn now, in the same session (a waiting retry fires).
    Retry(crate::cli::retry::RetryArgs),
    /// One turn per turn: prompt preview, status, tools, tokens, wall time.
    History {
        session: String,
        #[arg(long, short = 'n', default_value_t = 20)]
        limit: usize,
    },
    /// Run one prompt on several harnesses, one after another, and compare.
    Compare {
        /// HARNESS[/MODEL] per run: -m claude -m codex/gpt-5.5 …
        #[arg(long = "model", short = 'm', required = true)]
        harnesses: Vec<String>,
        /// The prompt.
        prompt: Vec<String>,
        #[arg(long)]
        cwd: Option<PathBuf>,
        #[arg(long)]
        policy: Option<String>,
        #[arg(long)]
        timeout: Option<u64>,
    },
    /// Print the agent guide: how a script or another agent drives acpmux. Also `guide`, `--guide`, `--skill`.
    #[command(alias = "guide")]
    Skill,
    /// Print the protocol capability ids this build serves, one per line (`--json`: an object).
    /// Needs no daemon: the app bundle records them for the web agent pane.
    Capabilities,
    /// Show or set presets: `preset`, `preset deepseek harness=opencode model=opencode-go/deepseek-v4-pro effort=low`,
    /// `preset omx harness=codex 'env.CODEX_HOME=${cwd}/.codex'`. `key=` clears one key; `--clear` removes the preset.
    #[command(alias = "presets")]
    Preset {
        name: Option<String>,
        /// key=value pairs: harness, model, effort, policy, description, env.KEY, args (a JSON list)
        pairs: Vec<String>,
        #[arg(long)]
        clear: bool,
    },
    /// Show or set default harness settings per model family or alias: `defaults`, `defaults claude`,
    /// `defaults claude model=claude-opus-5 effort=high policy=approve-edits prefer=claude-cr,claude`,
    /// `defaults deepseek prefer=opencode,pi models.opencode=opencode-go/deepseek-v4-pro models.pi=openrouter/deepseek/deepseek-v4`.
    /// A name that is not a family or profile is an alias: `-u deepseek` then works. `key=` clears one key; `--clear` removes the entry.
    Defaults {
        family: Option<String>,
        /// key=value pairs: model, effort, policy, prefer (comma list), env.KEY
        pairs: Vec<String>,
        #[arg(long)]
        clear: bool,
    },
    /// Print the last reply of a session (plain text).
    #[command(alias = "reply")]
    Last {
        session: String,
        /// How many replies, newest last.
        #[arg(long, short = 'n', default_value_t = 1)]
        count: usize,
    },
    /// List pending permission requests across sessions, and how to answer them.
    Pending,
    /// Send a prompt and stream the reply until the turn ends.
    #[command(
        alias = "prompt",
        alias = "send-keys",
        after_help = "A name several live sessions share is refused with the exact command for each.\n\nFrom an agent session, message other sessions with the `send` tool of the `acpmux` MCP server instead of this command in a shell: one call batches several (`messages: [{to, text}, {to, file}]`) or a tag, with one result row each, and the chat draws it as message cards."
    )]
    Send {
        /// The session: a name, `HOST/NAME`, an id or an id prefix. A bare name or prefix names
        /// the one live session that has it on this host or its peers; several are refused.
        #[arg(required_unless_present_any = ["status", "tag"])]
        session: Option<String>,
        /// Prompt text. Reads stdin when omitted or "-".
        prompt: Vec<String>,
        /// Send to every session, on every host, that carries this tag (`key` or `key=value`)
        /// and is not closed, as `--no-wait` messages: one delivery each, one line each. The
        /// sender's own session is skipped. Give the prompt without a SESSION. Exit 1 when any
        /// send failed, 4 when no live session carries the tag.
        #[arg(long, value_name = "TAG", conflicts_with_all = ["status", "prompt_id", "timeout", "quiet"])]
        tag: Option<String>,
        /// With --tag: print the sessions it would go to and send nothing.
        #[arg(long, requires = "tag")]
        dry_run: bool,
        /// Send this message into the running turn when the agent supports steering. On by
        /// default for an agent's send (--from, or one in an acpmux session) and with
        /// --no-wait; the person's send that waits for the reply queues unless given this. A
        /// send that waits and steers prints the reply of the turn it went into.
        #[arg(long, conflicts_with = "no_steer")]
        steer: bool,
        /// Queue behind the running turn, even an agent's send or one with --no-wait.
        #[arg(long)]
        no_steer: bool,
        /// Hand the message to this daemon and return at once, for a session here or on a
        /// peer: it prints the delivery id, and the daemon delivers it in the background,
        /// trying again while the peer is down (`acpmux send --status ID`).
        #[arg(long)]
        no_wait: bool,
        /// Print the state of a delivery `--no-wait` printed: queued, delivering, delivered or
        /// failed.
        #[arg(long, value_name = "ID", conflicts_with_all = ["session", "no_wait"])]
        status: Option<String>,
        /// Do not stream; print only the final assistant text.
        #[arg(long, short)]
        quiet: bool,
        /// Cancel the turn cooperatively after this many seconds and exit 3.
        #[arg(long)]
        timeout: Option<u64>,
        /// What to do when the turn asks for a permission: wait (default), deny, or fail (exit 5).
        #[arg(long, default_value = "wait")]
        on_permission: String,
        /// Report prompt_stalled (exit 1) when nothing happens for this many seconds after sending; 0 disables.
        #[arg(long, default_value_t = 30)]
        stall: u64,
        /// Send this prompt id again (from a `daemon_closed` error): the daemon runs an id once and
        /// answers a repeat with the first run's outcome.
        #[arg(long)]
        prompt_id: Option<String>,
        /// Send it as this agent's message: messages from agents that wait for a busy session go
        /// in together as one turn, after the person's own. An agent running in acpmux is
        /// named without it; elsewhere `ACPMUX_FROM` names it.
        #[arg(long, value_name = "NAME")]
        from: Option<String>,
        /// Replace your prompt still queued under KEY: a correction is never read after the
        /// order it corrects. Prints how many it replaced. A prompt whose turn started stays.
        #[arg(long, value_name = "KEY")]
        supersede: Option<String>,
        /// What your message asks of the receiver: block or blocker (you cannot go on until it
        /// acts), question (you wait for its answer), result or action (work you finished, or
        /// work for it; the default for an agent's message) or fyi. Another agent's message goes
        /// into the receiver's inbox, never a turn of its own: blockers wake an idle receiver,
        /// actions only from the session that started it or gave it its first work, FYIs never.
        #[arg(long, value_name = "CLASS", value_parser = ["block", "question", "result", "fyi", "blocker", "action"])]
        class: Option<String>,
        #[command(flatten)]
        inbox: SendThread,
        /// Send this file with the message (repeatable): an image reaches the agent and its
        /// transcript as an image, any other file as a link to its copy. Saved owner-only on the
        /// session's machine, a peer's too. Any size and number: large ones are uploaded first.
        #[arg(long, value_name = "FILE")]
        attach: Vec<PathBuf>,
    },
    /// Team-scoped durable messages. Requires Labs `meshRelay.teamMessaging`.
    Inbox(InboxArgs),
    /// Append a report to a human basket without waking any agent session.
    /// The target must be `reports:<person>`; the sender is the attached local
    /// ACP session (or `--from` when the daemon can bind that session).
    Deliver {
        #[arg(long, value_name = "TARGET")]
        target: String,
        /// Report text. Reads stdin when omitted or "-".
        prompt: Vec<String>,
        /// Stable id for retries; generated when omitted.
        #[arg(long)]
        id: Option<String>,
        /// Audience metadata (`leo`, `coordinator`, or `silent`).
        #[arg(long, default_value = "leo")]
        audience: String,
    },
    /// List sessions on every host: by default only live, named lanes, one short line each;
    /// `--json` with no filter is every session's full record.
    #[command(alias = "list", alias = "list-sessions", after_help = crate::cli::ls_table::HELP)]
    Ls(crate::cli::run::LsArgs),
    /// Open the TUI on a session, or on the session list.
    #[command(alias = "a")]
    Attach {
        session: Option<String>,
        /// Plain text stream instead of the TUI.
        #[arg(long)]
        plain: bool,
    },
    /// Be an ACP agent on stdin/stdout for an editor (Zed: `"command": "cmux",
    /// "args": ["acp", "stdio", "-m", "claude"]`). Relays to the daemon;
    /// the flags are defaults for each new session the editor creates.
    Stdio {
        /// HARNESS[/MODEL] for new sessions (`claude`, `codex/gpt-5.5`).
        #[arg(long, short)]
        model: Option<String>,
        /// A preset from `acpmux preset`.
        #[arg(long, short)]
        preset: Option<String>,
        #[arg(long, short)]
        effort: Option<String>,
        /// Permission policy: ask, approve-reads, approve-edits, approve-all, deny-all.
        #[arg(long)]
        policy: Option<String>,
    },
    /// Be an ACP agent that answers each prompt by running a plain CLI once
    /// (prompt on stdin, reply from stdout): makes any CLI a harness. In a
    /// profile: `args = ["cli-agent", "--", "/path/to/program"]`.
    CliAgent {
        /// Send only the prompt's last text block (a Chief turn's new
        /// messages), for a program that keeps its own memory.
        #[arg(long)]
        last_block: bool,
        /// Pass the prompt as the last argument instead of on stdin.
        #[arg(long)]
        prompt_arg: bool,
        /// Drop output up to the frame that echoes the prompt (unii).
        #[arg(long)]
        after_echo: bool,
        /// Put the session folder's AGENTS.md before the prompt.
        #[arg(long)]
        instructions: bool,
        /// Give the program a terminal as stdout and controlling terminal
        /// (stdin stays the prompt), for one that prints only to a terminal.
        #[arg(long)]
        tty: bool,
        /// The program and its arguments, after `--`.
        #[arg(trailing_var_arg = true, allow_hyphen_values = true, required = true)]
        command: Vec<String>,
    },
    /// Be an ACP agent backed by a UniiChat server (uniichat.com or your own
    /// `unii serve`), over UniiChat's own protocol: streaming, stop, images.
    /// Signs in with the token `unii login` keeps. In a profile:
    /// `args = ["uniichat-agent"]`.
    UniichatAgent {
        /// The server; default `$UNII_URL`, else https://uniichat.com.
        #[arg(long)]
        url: Option<String>,
        /// Where `unii` keeps its sign-ins; default `$UNII_HOME`, else ~/.unii.
        #[arg(long)]
        home: Option<std::path::PathBuf>,
        /// Send every text block of a prompt (UniiChat keeps its own memory,
        /// so by default only the last one: a Chief turn's new messages).
        #[arg(long)]
        whole_prompt: bool,
    },
    /// Print the dashboard URL and open it in the browser.
    Web {
        /// Only print the URL.
        #[arg(long)]
        no_open: bool,
        /// Print the URL with its bearer token (`--json` always has it in `url`;
        /// the browser this command opens always gets it).
        #[arg(long)]
        show_token: bool,
        /// Replace the dashboard token now: the old link, `ws://` peers that
        /// were given it and open dashboard connections stop working.
        #[arg(long)]
        rotate_token: bool,
    },
    /// Machines that run sessions: add, ls, status, pick, setup, update, enroll, doctor, ticket and more.
    /// The old spellings `host`, `hosts` and `peer` still work.
    #[command(subcommand, name = "machine", aliases = ["host", "hosts", "peer"])]
    Host(PeerCmd),
    /// Bring your own harness: list, add, doctor and reload harness profile
    /// files (~/.config/cmux/harnesses/<id>.toml). Also `cmux harness …`.
    #[command(subcommand)]
    Harness(HarnessCmd),
    /// Forum rules: announce one, list the current ones, ack one.
    #[command(subcommand)]
    Forum(crate::cli::forum::ForumCmd),
    /// Every chat on this device, from every harness: list, open, roots. Also `cmux chats …`.
    #[command(subcommand)]
    Chats(crate::cli::chats::ChatsCmd),
    /// Background processes agents left running (dev servers, watchers):
    /// list, show (everything one printed, live with --follow), kill,
    /// background (Ctrl-B: move a chat's running work there).
    #[command(subcommand, alias = "ps")]
    Process(crate::cli::process::ProcessCmd),
    /// This machine's git worktrees, cleaned up after the agents that made
    /// them: list, clean (archive work only there, then remove), restore,
    /// archives.
    #[command(subcommand, alias = "wt")]
    Worktree(crate::cli::worktree::WorktreeCmd),
    /// Everything else about one session: info, cancel, stop, rename, fork, set, allow, deny, answer, export, import, tail, queue.
    #[command(subcommand, alias = "s")]
    Session(SessionCmd),
    /// This machine as a hand of a Cloud Chief: pair, run, status.
    #[command(subcommand)]
    Hand(crate::hand::HandCmd),
    /// The daemon: run, status, start, restart, shutdown (also stop), config, harnesses, reload, models, schema.
    #[command(subcommand, alias = "d")]
    Daemon(DaemonCmd),
    /// Serve the local CodeRouter in a separate process.
    #[command(subcommand)]
    Router(RouterCmd),
    /// The cmux Computer Use helper v2 bridge: an MCP stdio server for one
    /// agent session (agent_tools.rs registers it; not for people).
    #[command(hide = true)]
    CuaMcp,
    /// The agent's request_secret and run_with_secret tools: an MCP stdio
    /// server for one agent session (agent_tools.rs registers it; not for people).
    #[command(hide = true)]
    SecretMcp,
    /// The agent's offer_session tool: an MCP stdio server for one agent
    /// session (agent_tools.rs registers it; not for people).
    #[command(hide = true)]
    OfferMcp,
    /// The agent's sub-session tools (start_session and the rest): an MCP
    /// stdio server for one agent session (agent_tools.rs registers it; not for people).
    #[command(hide = true)]
    SubsessionMcp,
    /// The agent's forum tools (announce, rules, ack): an MCP stdio server
    /// for one agent session (agent_tools.rs registers it; not for people).
    #[command(hide = true)]
    ForumMcp,
    /// The agent's Cloud repository tools (list_repos and add_repo), only on Cloud machines.
    #[command(hide = true)]
    RepoMcp,
    /// The agent's tools to message other sessions and read them (send, ls, last, info): an
    /// MCP stdio server for one agent session (agent_tools.rs registers it; not for people).
    #[command(hide = true)]
    AcpmuxMcp,
    // Old spellings, kept working but hidden from help.
    #[command(hide = true)]
    Tail {
        session: String,
        #[arg(long, default_value_t = 50)]
        last: u64,
        #[arg(long, short)]
        follow: bool,
        #[arg(long)]
        since: Option<String>,
    },
    #[command(hide = true)]
    TagCmd { session: String, assignments: Vec<String>, remove: Vec<String>, ttl: Option<u64> },
    #[command(hide = true)]
    RulesCmd { session: String, rules: Option<String>, clear: bool },
    #[command(hide = true)]
    LimitsCmd { session: String, max: Option<u32>, clear: bool },
    #[command(hide = true)]
    TurnCapCmd { session: String, minutes: Option<u64>, off: bool, clear: bool },
    #[command(hide = true, subcommand)]
    QueueCmd(crate::cli::session_queue::QueueCmd),
    #[command(hide = true)]
    SessionInboxCmd(SessionInboxTarget),
    #[command(hide = true)]
    Schema,
    #[command(hide = true)]
    Models {
        #[arg(long)]
        refresh: bool,
    },
    #[command(hide = true)]
    Info {
        session: String,
        #[arg(long, value_name = "FIELD[,FIELD…]")]
        fields: Option<String>,
    },
    #[command(hide = true)]
    Cancel { session: String },
    #[command(hide = true, alias = "kill-session")]
    Kill {
        session: String,
        #[arg(long)]
        purge: bool,
        /// Set from `session stop --if-idle`; the hidden spelling takes no condition.
        #[arg(skip)]
        condition: StopIf,
    },
    #[command(hide = true)]
    RestartAgent { session: String },
    #[command(hide = true)]
    ResumeQueue { session: String },
    #[command(hide = true)]
    InboxDigest {
        session: String,
        #[arg(long)]
        dry_run: bool,
    },
    #[command(hide = true, alias = "rename-session")]
    Rename { session: String, new_name: String },
    #[command(hide = true)]
    Fork {
        session: String,
        #[arg(long, short)]
        name: Option<String>,
        #[arg(long)]
        cwd: Option<PathBuf>,
        /// Fork even when this host refuses new sessions (disk under its floor; max_lanes only warns).
        #[arg(long)]
        force_admit: bool,
    },
    #[command(hide = true)]
    Set { session: String, assignment: String },
    #[command(hide = true)]
    Allow { session: String, option: Option<String> },
    #[command(hide = true)]
    Deny { session: String },
    #[command(hide = true)]
    Answer {
        session: String,
        #[arg(long = "answer", value_name = "QUESTION=CHOICE")]
        answer: Vec<String>,
    },
    #[command(hide = true)]
    Export {
        session: String,
        #[arg(long)]
        dest: Option<PathBuf>,
    },
    #[command(hide = true)]
    Import {
        path: PathBuf,
        #[arg(long, short)]
        name: Option<String>,
    },
    #[command(hide = true)]
    MoveSessions {
        sessions: Vec<String>,
        host: String,
        all_idle: bool,
        interrupt: bool,
        leave_dirty: bool,
        cwd: Option<String>,
        dry_run: bool,
    },
    #[command(hide = true)]
    Transfer {
        session: String,
        #[arg(long)]
        to: PathBuf,
        #[arg(long)]
        cwd: Option<String>,
        #[arg(long, short)]
        name: Option<String>,
        #[arg(long)]
        interrupt: bool,
    },
    #[command(hide = true)]
    Harnesses,
    #[command(hide = true)]
    Reload,
    #[command(hide = true)]
    Retention(RetentionArgs),
    #[command(hide = true)]
    Status {
        #[arg(long)]
        show_token: bool,
    },
    /// `daemon start`: status, starting a daemon first when none runs.
    #[command(hide = true)]
    DaemonStart { person_key_fd: Option<i32>, show_token: bool },
    #[command(hide = true)]
    DaemonRestart,
    #[command(hide = true, alias = "kill-server")]
    Shutdown {
        /// Accepted for callers of older builds; hosted agents keep running anyway.
        #[arg(long, hide = true, conflicts_with = "end_agents")]
        keep_agents: bool,
        /// Signal service restart to clients while stopping for an external updater.
        #[arg(long, conflicts_with = "end_agents")]
        restart: bool,
        /// End every agent process too, hosted agents and their hosts included.
        #[arg(long)]
        end_agents: bool,
    },
    #[command(hide = true)]
    Config {
        #[arg(long)]
        show_token: bool,
        /// Set a daemon host-wide setting as KEY=VALUE (for example,
        /// `session.memory_mb=6144`, `session.swap_mb=2048`,
        /// `session.tasks_max=8192`, `session.sessions_tasks_max=131072` or
        /// `session.cpu_class=normal`).
        #[arg(long, value_name = "KEY=VALUE")]
        set: Option<String>,
    },
    #[command(hide = true)]
    DaemonRun {
        /// Also serve WebSocket clients, e.g. 127.0.0.1:47811
        #[arg(long)]
        listen: Option<String>,
        /// Bearer token WebSocket clients must present.
        #[arg(long)]
        token: Option<String>,
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
    },
}

#[derive(Args)]
pub struct DispatchArgs {
    /// Local Markdown/text brief file (use `-` for stdin).
    pub brief: PathBuf,
    /// Machine name, `auto` for the least-loaded pick, or `local` (`--host` and `--target` still work).
    #[arg(long = "machine", aliases = ["host", "target"], value_name = "MACHINE", default_value = "auto")]
    pub host: String,
    #[arg(long)]
    pub title: Option<String>,
    #[arg(long)]
    pub to: Option<String>,
    #[arg(long)]
    pub stop_condition: Option<String>,
    /// HARNESS[/MODEL] or profile; any ACP harness is accepted.
    #[arg(long, short)]
    pub model: Option<String>,
    #[arg(long)]
    pub preset: Option<String>,
    #[arg(long)]
    pub policy: Option<String>,
    #[arg(long)]
    pub cwd: Option<PathBuf>,
}

#[derive(Subcommand)]
pub enum HarnessCmd {
    /// Install or inspect cmux's opt-in managed Codex runtime.
    CodexRuntime {
        #[command(subcommand)]
        action: CodexRuntimeCmd,
    },
    /// Every harness with its kind, source file and problems.
    #[command(alias = "ls")]
    List {
        /// Also list the folder profiles in DIR/.cmux/harnesses with their state.
        #[arg(long)]
        folder: Option<PathBuf>,
    },
    /// Write a new profile file into ~/.config/cmux/harnesses and check it.
    #[command(after_help = crate::cli::harness::add_help())]
    Add {
        /// Profile id (file name); default: the example's id or the command's name.
        id: Option<String>,
        /// The program to run: a name on PATH or an absolute path.
        #[arg(long)]
        command: Option<String>,
        /// acp (Agent Client Protocol over stdio) or terminal (a CLI/TUI without ACP).
        #[arg(long, default_value = "acp")]
        protocol: String,
        /// Start from a shipped example: claude, codex, opencode, pi, gemini, aider, or your
        /// own model endpoint: anthropic-endpoint, openai-endpoint (with --base-url, --model).
        #[arg(long)]
        example: Option<String>,
        /// anthropic-endpoint / openai-endpoint: the endpoint's base URL (https; http only
        /// to localhost or 127.0.0.1).
        #[arg(long)]
        base_url: Option<String>,
        /// anthropic-endpoint / openai-endpoint: the model id the endpoint serves.
        #[arg(long)]
        model: Option<String>,
        /// anthropic-endpoint / openai-endpoint: the Keychain item that holds the key
        /// (default: cmux-harness/ID/KEY, which `cmux harness secret set ID KEY` writes).
        #[arg(long)]
        keychain_item: Option<String>,
        /// anthropic-endpoint / openai-endpoint: the name the model picker shows.
        #[arg(long)]
        name: Option<String>,
        /// Replace an existing file.
        #[arg(long)]
        force: bool,
        /// ID is an ACP Registry agent (`cmux harness registry`): write a
        /// profile that starts it at the registry's pinned version (its
        /// installed program, else npx, else uvx).
        #[arg(long, conflicts_with_all = ["command", "example"])]
        registry: bool,
        /// The icon cmux shows for it: one emoji, an SF Symbol name (hammer.fill), an agent
        /// mark (claude, goose, ...) or an .svg/.png file. Default: the mark of the agent its
        /// command runs, else a monogram.
        #[arg(long)]
        icon: Option<String>,
    },
    /// Show or set the icon cmux shows for one of your harnesses: one emoji, an SF Symbol
    /// name (hammer.fill), an agent mark (claude, goose, ...) or an .svg/.png file (copied
    /// next to the profile). With no VALUE, prints the icon cmux shows now and why.
    Icon {
        id: String,
        value: Option<String>,
        /// Remove the icon line: cmux picks the icon again.
        #[arg(long, conflicts_with = "value")]
        clear: bool,
    },
    /// Sign in to a harness with its own ACP sign-in (or `claude auth login`
    /// for Claude Code). `--status` checks it; `--list` shows the methods.
    Login {
        id: String,
        /// The sign-in method id (default: the harness's first browser or terminal sign-in).
        #[arg(long)]
        method: Option<String>,
        /// Show the sign-in methods and whether the harness is signed in.
        #[arg(long)]
        list: bool,
        /// Only check whether the harness is signed in.
        #[arg(long)]
        status: bool,
    },
    /// The ACP Registry's agents and how each can start here.
    Registry {
        /// Fetch the registry now instead of reading the cached copy.
        #[arg(long)]
        refresh: bool,
    },
    /// Start the harness in a temp folder, run the ACP handshake and one
    /// prompt, and print each step with an exact fix. Never prints env values.
    /// An id that is no catalog harness is looked up as a folder profile
    /// (DIR/.cmux/harnesses/ID.toml in --folder or the current folder, or
    /// their nearest parent); an enabled one starts inside its folder.
    Doctor {
        id: String,
        /// Where to look for a folder profile (default: the current folder).
        #[arg(long)]
        folder: Option<PathBuf>,
        /// Stop after session/new: send no prompt (no model call).
        #[arg(long)]
        no_prompt: bool,
        /// Seconds each step may wait for the harness.
        #[arg(long, default_value_t = 120)]
        timeout: u64,
    },
    /// Allow a folder profile (DIR/.cmux/harnesses/ID.toml) in chats inside
    /// DIR: shows the command and env, then asks. The folder must be trusted.
    Enable {
        id: String,
        #[arg(long)]
        folder: PathBuf,
        /// Confirm without the prompt (needed without a terminal).
        #[arg(long)]
        yes: bool,
    },
    /// Withdraw a folder profile's confirmation.
    Disable {
        id: String,
        #[arg(long)]
        folder: PathBuf,
    },
    /// Run a protocol = "terminal" harness (a CLI/TUI without ACP) in this
    /// terminal with its profile env; `--tab` (cmux) opens it in a new tab.
    Run {
        id: String,
        /// The folder to run in (default: the current folder).
        #[arg(long)]
        cwd: Option<PathBuf>,
        /// The model for `${model}` (default: the profile's).
        #[arg(long)]
        model: Option<String>,
        /// Open a new tab in the current pane (cmux only).
        #[arg(long)]
        tab: bool,
    },
    /// Secrets for harness env keys, kept in the system secret store.
    #[command(subcommand)]
    Secret(SecretCmd),
    /// Tell the running daemon to read the profile files again.
    Reload,
    /// Print the guide an agent follows to integrate a harness (schema,
    /// doctor loop, examples, security rules).
    Guide,
    /// Move a profile file from your harness folder to a backup
    /// (~/.acpmux/harness-backups); `restore` brings it back.
    Remove { id: String },
    /// Move a backup that `remove` made back into your harness folder.
    Restore { backup: String },
}

#[derive(Subcommand)]
pub enum CodexRuntimeCmd {
    /// Download and verify the pinned official Codex release.
    Install,
    /// Print the managed runtime status.
    Status,
}

#[derive(Subcommand)]
pub enum SecretCmd {
    /// Store a value for ID's env KEY (Keychain on macOS, secret-tool
    /// elsewhere) and write `KEY = { keychain = "cmux-harness/ID/KEY" }` into
    /// the profile file. Reads a hidden prompt, or stdin; never prints it.
    Set { id: String, key: String },
}

#[derive(Subcommand)]
pub enum SessionCmd {
    /// Queue a new session on a mesh host; prints a receipt, not completed execution.
    Start(crate::cli::mesh_control::StartArgs),
    /// Read one mesh lifecycle receipt without waiting.
    Receipt { message_id: String },
    /// Show session details.
    Info {
        session: String,
        /// Print only these comma-separated fields, one per line as `field<TAB>value` (a single
        /// field prints its bare value); a dotted path reads a nested one (`turn.activity`).
        /// With --json, an object of just those fields.
        #[arg(long, value_name = "FIELD[,FIELD…]")]
        fields: Option<String>,
    },
    /// Cancel the running turn.
    Cancel { session: String },
    /// Stop the agent process. The session stays resumable.
    #[command(alias = "kill")]
    Stop {
        session: String,
        #[command(flatten)]
        mesh: crate::cli::mesh_control::RouteArgs,
        /// Also delete the log.
        #[arg(long)]
        purge: bool,
        #[command(flatten)]
        condition: StopIf,
    },
    /// Restart the agent process in the same conversation: now when the
    /// session is between turns, else when its turn ends (never cancelled).
    /// It then runs the installed version and gets a new caller token (after
    /// a daemon restart left it the earlier daemon's).
    Restart { session: String },
    /// Rename a session.
    Rename { session: String, new_name: String },
    /// Run the queued prompts a failed turn held. An agent or a script may resume a
    /// queue; only answering a permission or a question needs the cmux app. On a machine a
    /// person works at, a stopped chat first moves to a fleet machine, as `session move --machine
    /// auto` does; when none takes it, it resumes here and says why.
    Resume {
        session: String,
        #[command(flatten)]
        mesh: crate::cli::mesh_control::RouteArgs,
    },
    /// Fork a session into a new one that shares the history so far.
    Fork {
        session: String,
        #[arg(long, short)]
        name: Option<String>,
        #[arg(long)]
        cwd: Option<PathBuf>,
        /// Fork even when this host refuses new sessions (disk under its floor; max_lanes only warns).
        #[arg(long)]
        force_admit: bool,
    },
    /// Change mode, model, a config option, or the permission policy: key=value.
    Set {
        session: String,
        assignment: Option<String>,
        /// Claim a team-scoped address (for example `coordinator`).
        #[arg(long, conflicts_with = "assignment")]
        team_address: Option<String>,
    },
    /// Answer a pending permission request. The daemon accepts an allow
    /// only from the cmux app (approve it on the Mac app); a deny option
    /// works from here.
    Allow { session: String, option: Option<String> },
    /// Reject a pending permission request.
    Deny { session: String },
    /// Answer a pending agent question: one --answer per question, keyed by
    /// question text, id or header; the choice is option labels or ids
    /// (comma-separated for multi-select) or your own text. With no
    /// --answer, print the questions and the command. An answer is an
    /// allow: only the cmux app may send it.
    Answer {
        session: String,
        #[arg(long = "answer", value_name = "QUESTION=CHOICE")]
        answer: Vec<String>,
    },
    /// Export a session bundle.
    Export {
        session: String,
        #[arg(long)]
        dest: Option<PathBuf>,
    },
    /// Import a session bundle directory.
    Import {
        path: PathBuf,
        #[arg(long, short)]
        name: Option<String>,
    },
    /// Move chats to another machine's daemon (one you added), with their history, queue and
    /// draft: the branch of a chat's worktree is pushed and checked out there as a fresh
    /// worktree, a plain folder under the home maps to the same path under the machine's home. The
    /// chat here never runs again, and `resolve` and agent links lead to its new place.
    Move {
        /// The chats to move (ids or names); none with --all-idle.
        #[arg(required_unless_present = "all_idle")]
        sessions: Vec<String>,
        /// The machine to move them to, or `auto`: `machine pick`'s choice among your machines
        /// (never a reserved one), one machine per checkout. `--host` still works.
        #[arg(long = "machine", alias = "host", value_name = "MACHINE")]
        host: String,
        /// Every open chat here that is between turns.
        #[arg(long, conflicts_with = "sessions")]
        all_idle: bool,
        /// Stop a running turn instead of refusing the move.
        #[arg(long)]
        interrupt: bool,
        /// Move a chat whose checkout has uncommitted changes; they stay on this machine.
        #[arg(long)]
        leave_dirty: bool,
        /// Run the moved chats in this folder on the machine, as it is there: no worktree is made
        /// and no branch pushed. For a folder outside this machine's home.
        #[arg(long, value_name = "PATH")]
        cwd: Option<String>,
        /// Say where each chat would go and change nothing.
        #[arg(long)]
        dry_run: bool,
    },
    /// Move a chat, with its history, queue and draft, to the daemon at another socket.
    Transfer {
        session: String,
        /// The other daemon's socket (a sibling build's).
        #[arg(long)]
        to: PathBuf,
        /// The chat's folder there, when it has another path.
        #[arg(long)]
        cwd: Option<String>,
        #[arg(long, short)]
        name: Option<String>,
        /// Stop a running turn instead of refusing the move.
        #[arg(long)]
        interrupt: bool,
    },
    /// Print the last raw events as JSON lines; -f keeps following.
    Tail {
        session: String,
        #[arg(long, default_value_t = 50)]
        last: u64,
        #[arg(long, short)]
        follow: bool,
        /// Start after this cursor (`<sessionId>:<seq>` or a seq). A cursor past the log is an error.
        #[arg(long)]
        since: Option<String>,
    },
    /// Label a session: key=value pairs, `--remove key`, `--ttl seconds`.
    Tag {
        session: String,
        assignments: Vec<String>,
        #[arg(long)]
        remove: Vec<String>,
        #[arg(long)]
        ttl: Option<u64>,
    },
    /// Per-tool permission rules above the policy: a JSON object, `@file`, or `--clear`; omit to show.
    Rules {
        session: String,
        rules: Option<String>,
        #[arg(long)]
        clear: bool,
    },
    /// How many of its sub-sessions run at once (more wait their turn), how many run and wait
    /// now, and its other sub-session limits. `--max N` sets it, `--clear` falls back to the
    /// workspace's, the settings' or the default (1000); setting takes the app or a parent session.
    Limits {
        session: String,
        /// Most sub-sessions running at once (1 to 1000).
        #[arg(long, value_parser = clap::value_parser!(u32).range(1..=1000), conflicts_with = "clear")]
        max: Option<u32>,
        /// Drop the session's own value.
        #[arg(long)]
        clear: bool,
    },
    /// The turn cap: past it, the running turn takes no other agent's message (they wait for the
    /// next turn, and the agent is told once to end its turn); the person's still go in. Omit
    /// the flags to show it; setting it takes the app or this socket, never an agent.
    TurnCap {
        session: String,
        /// The cap in minutes (1 to 1440).
        #[arg(long, value_parser = clap::value_parser!(u64).range(1..=1440), conflicts_with_all = ["off", "clear"])]
        minutes: Option<u64>,
        /// No cap for this session, whatever its default.
        #[arg(long, conflicts_with = "clear")]
        off: bool,
        /// Drop the session's own value: back to its default.
        #[arg(long)]
        clear: bool,
    },
    /// The chat's inbox: other agents' messages, in threads, which take no turn of its own.
    /// With --thread, that thread's messages whole, newest first; without it, every thread.
    ///
    /// With --digest, the other agents' messages still waiting in a busy session's queue (the
    /// kinds that do not go to the inbox yet) go in as ONE prompt, now: steered into its running
    /// turn when its agent steers, else at the head of the agents' messages in its queue, behind
    /// the person's prompts (which it never touches). Each original keeps its full text in the
    /// log under its promptId. With --dry-run, prints that digest and changes nothing. Only this
    /// machine's person or the session's own agent may drain it.
    Inbox {
        session: String,
        #[command(flatten)]
        opts: SessionInboxOpts,
    },
    /// One line per turn.
    History {
        session: String,
        #[arg(long, short = 'n', default_value_t = 20)]
        limit: usize,
    },
    /// The prompts waiting for the running turn: list, remove PROMPT_ID..., clear --from-agents.
    #[command(subcommand)]
    Queue(crate::cli::session_queue::QueueCmd),
}

// The inbox's flags (`hub/inbox.rs`) are `Args` of their own, flattened: each builds in its own
// frame. Inline, the derived builder's one frame for every command's flags overflowed libtest's
// 2 MiB thread in a debug build.

/// `acpmux send --pr N | --thread T`: the receiver's inbox thread.
#[derive(Args, Default)]
pub struct SendThread {
    /// The pull request your message is about: the receiver's inbox threads it with the
    /// others about it.
    #[arg(long, value_name = "N")]
    pub pr: Option<u64>,
    /// The inbox thread your message goes in: a topic, or a threadId the receiver's inbox
    /// named (default: your messages about the PR its first line names, else all yours).
    #[arg(long, value_name = "THREAD", conflicts_with = "pr")]
    pub thread: Option<String>,
}

/// `acpmux session inbox NAME`'s flags.
#[derive(Args, Default)]
pub struct SessionInboxOpts {
    /// A threadId, as the list names it.
    #[arg(long, value_name = "THREAD", conflicts_with_all = ["digest", "dry_run"])]
    pub thread: Option<String>,
    /// With --thread: mark its messages read, as the agent's inbox_read does.
    #[arg(long, requires = "thread")]
    pub mark_read: bool,
    /// Drain the agent messages waiting in its queue into one digest prompt now.
    #[arg(long)]
    pub digest: bool,
    /// Print that digest and change nothing.
    #[arg(long)]
    pub dry_run: bool,
}

/// `acpmux session inbox NAME [--thread T [--mark-read]]`, flattened (`session_inbox.rs`).
#[derive(Args)]
pub struct SessionInboxTarget {
    pub session: String,
    #[arg(long)]
    pub thread: Option<String>,
    #[arg(long)]
    pub unread: bool,
}

#[derive(Args)]
pub struct InboxArgs {
    /// Continue browsing from the previous JSON response's `next` cursor.
    #[arg(long)]
    pub before: Option<u64>,
    #[command(subcommand)]
    pub command: Option<InboxCmd>,
}

#[derive(Subcommand)]
pub enum InboxCmd {
    /// List team messages currently held by the hub.
    List,
    /// Read one message by id (the message remains acknowledged only when `ack` is used).
    Read { id: String },
    /// Acknowledge one team message.
    Ack { id: String },
}

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
    /// Restart the daemon, preserving hosted sessions so they resume on startup.
    Restart,
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
}

#[derive(Args)]
pub struct NewArgs {
    /// A preset from `acpmux preset`: harness plus model, effort, policy, env. `-m` and `-e` still win.
    #[arg(long, short)]
    pub preset: Option<String>,
    /// Create the session on this machine (see `acpmux machine ls`). `--cwd` is then a remote path
    /// inside the machine's webRoots (made when missing; left out, a scratch folder). The machine
    /// starts it asking: `--mode`, and a `--policy` other than ask from a machine that serves this
    /// machine as a remote client, are refused with the command that works instead.
    /// `auto` (`auto-build` for a build) takes `acpmux machine pick`'s choice. Left out on a
    /// machine the fleet registry marks interactive (a person's own Mac), the session is placed
    /// as with `auto`, off every such machine, unless `--cwd` or `-w` names a folder here;
    /// `local` keeps it on this machine. `--host` still works.
    #[arg(long = "machine", alias = "host", value_name = "MACHINE")]
    pub host: Option<String>,
    /// Session name. Generated when omitted. With a launcher flag it is lowercased
    /// and `/` or spaces become `-` (`gui/x` is `gui-x`).
    #[arg(long, short)]
    pub name: Option<String>,
    #[arg(long)]
    pub cwd: Option<PathBuf>,
    /// Permission policy: ask, approve-reads, approve-edits, approve-all, deny-all.
    #[arg(long)]
    pub policy: Option<String>,
    /// The harness mode to start in (e.g. `auto`). One that does not ask needs the
    /// person in cmux NEXT, a preset the person approved, or this command running
    /// inside a session that is in that mode.
    #[arg(long)]
    pub mode: Option<String>,
    /// HARNESS[/MODEL]: a family or profile name (`claude`, `codex`, `omp`), optionally with a model
    /// (`claude/opus`, `codex/gpt-5.5`, `opencode/zai/glm-5.1`). Omitted: the default harness and its defaults.
    #[arg(long, short)]
    pub model: Option<String>,
    /// Thinking effort: default, low, medium, high, xhigh, max (Codex adds ultra).
    #[arg(long, short)]
    pub effort: Option<String>,
    /// Start on exactly the harness SESSION ran (profile, preset, model, effort), for a session
    /// that takes over SESSION's work. A successor named by a `succeeds=` or `area=` tag, its
    /// name (`NAME-2`) or --report-to is warned about when its harness differs, and refused
    /// when it would start on the bare default where SESSION ran a named profile.
    #[arg(long, value_name = "SESSION", conflicts_with_all = ["model", "preset", "effort"])]
    pub harness_from: Option<String>,
    /// Optional first prompt.
    pub prompt: Vec<String>,
    /// Label the new session (repeatable `key=value`).
    #[arg(long = "tag", value_name = "K=V")]
    pub tags: Vec<String>,
    /// Do not open the TUI after creating.
    #[arg(long, short)]
    pub detach: bool,
    /// With a prompt: print only the final reply (implied by `acpmux run`).
    #[arg(long, short)]
    pub quiet: bool,
    /// Delete the session after the reply (implied by `acpmux exec`).
    #[arg(long)]
    pub ephemeral: bool,
    /// Cancel the turn cooperatively after this many seconds and exit 3.
    #[arg(long)]
    pub timeout: Option<u64>,
    /// When the turn asks for a permission: wait (default), deny, or fail (exit 5).
    #[arg(long, default_value = "wait")]
    pub on_permission: String,
    /// Retry the turn on an agent-internal error, only when it produced nothing yet.
    #[arg(long, default_value_t = 0)]
    pub retries: u32,
    /// Report prompt_stalled (exit 1) when nothing happens for this many seconds; 0 disables.
    #[arg(long, default_value_t = 30)]
    pub stall: u64,
    /// Send the first prompt with this id again (from a `daemon_closed` error); it runs once.
    #[arg(long)]
    pub prompt_id: Option<String>,
    /// Start in the git worktree named by --name of REPO's repository,
    /// `~/.cmux/worktrees/<project>/<name>` on branch `cmux/<name>` from BASE
    /// (a ref or commit; default REPO's current branch). Made when missing,
    /// reused when there; implies --reuse. Replaces --cwd.
    #[arg(long, value_name = "REPO[@BASE]")]
    pub worktree: Option<String>,
    /// Read the first prompt from this file (after any prompt words), now; `-`
    /// reads stdin. A missing or empty file fails before anything starts.
    #[arg(long, value_name = "FILE")]
    pub prompt_file: Option<PathBuf>,
    /// Tell the new session that this session started it and how to report back.
    #[arg(long, value_name = "SESSION")]
    pub report_to: Option<String>,
    /// Start it as SESSION's sub-session, of any harness (`-m codex`): it lists under SESSION's
    /// chat and SESSION's agent reads, messages and stops it with its sub-session tools. SESSION
    /// is the session this command runs in (`$ACPMUX_SESSION_ID`) or one of its sub-sessions.
    /// Needs a prompt; prints the child's reply when its turn ends (with -d, only starts it).
    #[arg(long, value_name = "SESSION")]
    pub parent: Option<String>,
    /// Show the session in the cmux app's sidebar, in this workspace group
    /// (made when missing). Runs `cmux agent open` on this machine, including
    /// with --machine: the agent runs remotely, its workspace opens here. A human
    /// label, matched ignoring case and outer spaces; an id is refused (exit 2).
    #[arg(long, value_name = "GROUP")]
    pub group: Option<String>,
    /// When a session named --name already exists, use it instead of failing;
    /// the first prompt is not sent to it again.
    #[arg(long)]
    pub reuse: bool,
    /// Create the session even when its host refuses new ones (disk under its
    /// floor; the fleet registry's max_lanes only warns). The daemon logs it.
    #[arg(long)]
    pub force_admit: bool,
}

/// `session stop`'s condition (`hub/stop_if_idle.rs`). Not with `--mesh`: the mesh hub's stop
/// cannot carry it.
#[derive(Args, Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StopIf {
    /// Stop only when the session is idle: no turn (one admitted but not started yet included),
    /// queued prompt, pending permission, agent request, background subagent or process. Checked
    /// under the lock that admits turns, so none starts between the check and the stop. Refused:
    /// exit 6, error `busy`, with `busyWith` and the session's revision.
    #[arg(long, conflicts_with = "mesh")]
    pub if_idle: bool,
    /// With --if-idle: stop only while the session's revision (its `lastSeq` in `acpmux ls
    /// --json` or `session info --json`) is still REV. Refused: exit 6, error `revision_moved`.
    #[arg(long, value_name = "REV", requires = "if_idle")]
    pub expect_revision: Option<u64>,
}

/// Map the grouped spellings onto the flat handlers.
pub fn flatten(c: Command) -> Command {
    match c {
        Command::Session(sc) => match sc {
            SessionCmd::Info { session, fields } => Command::Info { session, fields },
            SessionCmd::Cancel { session } => Command::Cancel { session },
            SessionCmd::Stop { session, purge, mesh, condition } if !mesh.mesh => {
                Command::Kill { session, purge, condition }
            }
            SessionCmd::Restart { session } => Command::RestartAgent { session },
            SessionCmd::Rename { session, new_name } => Command::Rename { session, new_name },
            SessionCmd::Resume { session, mesh } if !mesh.mesh => Command::ResumeQueue { session },
            SessionCmd::Inbox { session, opts } if opts.digest || opts.dry_run => {
                Command::InboxDigest { session, dry_run: opts.dry_run || !opts.digest }
            }
            control @ (SessionCmd::Start(_)
            | SessionCmd::Receipt { .. }
            | SessionCmd::Stop { .. }
            | SessionCmd::Resume { .. }) => Command::Session(control),
            SessionCmd::Fork { session, name, cwd, force_admit } => {
                Command::Fork { session, name, cwd, force_admit }
            }
            SessionCmd::Set { session, assignment, team_address } => Command::Set {
                session,
                assignment: assignment
                    .or_else(|| team_address.map(|address| format!("team-address={address}")))
                    .unwrap_or_default(),
            },
            SessionCmd::Allow { session, option } => Command::Allow { session, option },
            SessionCmd::Deny { session } => Command::Deny { session },
            SessionCmd::Answer { session, answer } => Command::Answer { session, answer },
            SessionCmd::Export { session, dest } => Command::Export { session, dest },
            SessionCmd::Import { path, name } => Command::Import { path, name },
            SessionCmd::Transfer { session, to, cwd, name, interrupt } => {
                Command::Transfer { session, to, cwd, name, interrupt }
            }
            SessionCmd::Move { sessions, host, all_idle, interrupt, leave_dirty, cwd, dry_run } => {
                Command::MoveSessions {
                    sessions,
                    host,
                    all_idle,
                    interrupt,
                    leave_dirty,
                    cwd,
                    dry_run,
                }
            }
            SessionCmd::Tail { session, last, follow, since } => {
                Command::Tail { session, last, follow, since }
            }
            SessionCmd::Tag { session, assignments, remove, ttl } => {
                Command::TagCmd { session, assignments, remove, ttl }
            }
            SessionCmd::Limits { session, max, clear } => {
                Command::LimitsCmd { session, max, clear }
            }
            SessionCmd::TurnCap { session, minutes, off, clear } => {
                Command::TurnCapCmd { session, minutes, off, clear }
            }
            SessionCmd::Inbox { session, opts } => Command::SessionInboxCmd(SessionInboxTarget {
                session,
                thread: opts.thread,
                unread: opts.mark_read,
            }),
            SessionCmd::Rules { session, rules, clear } => {
                Command::RulesCmd { session, rules, clear }
            }
            SessionCmd::History { session, limit } => Command::History { session, limit },
            SessionCmd::Queue(q) => Command::QueueCmd(q),
        },
        Command::Daemon(dc) => match dc {
            DaemonCmd::Run {
                listen,
                token,
                memory,
                log,
                ready_fd,
                person_key_fd,
                allow_dev_origin,
                dev,
            } => Command::DaemonRun {
                listen,
                token,
                memory,
                log,
                ready_fd,
                person_key_fd,
                allow_dev_origin,
                dev,
            },
            DaemonCmd::Status { show_token } => Command::Status { show_token },
            DaemonCmd::Start { person_key_fd, show_token } => {
                Command::DaemonStart { person_key_fd, show_token }
            }
            DaemonCmd::Shutdown { keep_agents, end_agents, restart } => {
                Command::Shutdown { keep_agents, end_agents, restart }
            }
            DaemonCmd::Restart => Command::DaemonRestart,
            DaemonCmd::Config { show_token, set } => Command::Config { show_token, set },
            DaemonCmd::Harnesses => Command::Harnesses,
            DaemonCmd::Reload => Command::Reload,
            DaemonCmd::Retention(args) => Command::Retention(args),
            DaemonCmd::Schema => Command::Schema,
            DaemonCmd::Models { refresh } => Command::Models { refresh },
        },
        Command::Host(pc) => Command::Host(pc),
        Command::Router(RouterCmd::Serve) => Command::Router(RouterCmd::Serve),
        other => other,
    }
}

#[derive(Subcommand)]
pub enum RouterCmd {
    /// Start the phase-one local router listeners.
    Serve,
}

#[cfg(test)]
mod help_contract_tests {
    use super::Cli;
    use clap::{CommandFactory, Parser};
    use std::collections::{HashMap, HashSet};

    const REMOTE_DOCS: &[(&str, &str)] = &[
        (
            "docs/remote-agents-and-cloud.md",
            include_str!("../../../../../docs/remote-agents-and-cloud.md"),
        ),
        ("acpmux README", include_str!("../../README.md")),
        ("acpmux skill", include_str!("../../skills/acpmux/SKILL.md")),
        ("docs/cli-sessions.md", include_str!("../../docs/cli-sessions.md")),
        ("docs/cli-hosts.md", include_str!("../../docs/cli-hosts.md")),
        ("docs/cli-harnesses.md", include_str!("../../docs/cli-harnesses.md")),
        ("docs/cli-daemon.md", include_str!("../../docs/cli-daemon.md")),
        ("docs/cli-work.md", include_str!("../../docs/cli-work.md")),
    ];

    fn shell_words(text: &str) -> Vec<String> {
        let mut words = Vec::new();
        let mut word = String::new();
        let mut quote = None;
        let mut escaped = false;
        for character in text.chars() {
            if escaped {
                word.push(character);
                escaped = false;
                continue;
            }
            if character == '\\' && quote != Some('\'') {
                escaped = true;
                continue;
            }
            if let Some(closing) = quote {
                if character == closing {
                    quote = None;
                } else {
                    word.push(character);
                }
                continue;
            }
            match character {
                '\'' | '"' => quote = Some(character),
                ';' | '#' => break,
                character if character.is_whitespace() => {
                    if !word.is_empty() {
                        words.push(std::mem::take(&mut word));
                    }
                }
                character => word.push(character),
            }
        }
        if !word.is_empty() {
            words.push(word);
        }
        words
            .into_iter()
            .map(|word| word.trim_matches(|character| "`[]()<>.,:".contains(character)).to_owned())
            .collect()
    }

    fn tokens(text: &str, binary: &str) -> Vec<Vec<String>> {
        let mut snippets = Vec::new();
        let mut in_fence = false;
        for line in text.lines() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("```") {
                in_fence = !in_fence;
                continue;
            }
            if in_fence && (trimmed == binary || trimmed.starts_with(&format!("{binary} "))) {
                snippets.push(trimmed.to_owned());
            }
            let mut rest = line;
            while let Some(open) = rest.find('`') {
                let after_open = &rest[open + 1..];
                let Some(close) = after_open.find('`') else { break };
                let snippet = &after_open[..close];
                if snippet.trim_start() == binary
                    || snippet.trim_start().starts_with(&format!("{binary} "))
                {
                    snippets.push(snippet.trim().to_owned());
                }
                rest = &after_open[close + 1..];
            }
        }

        snippets
            .into_iter()
            .flat_map(|snippet| {
                snippet
                    .split(';')
                    .filter_map(|part| {
                        let words = shell_words(part.trim_start_matches("$ "));
                        (words.first().is_some_and(|word| word == binary) && words.len() > 1)
                            .then_some(words)
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
    }

    fn command_shapes() -> HashMap<Vec<String>, HashSet<String>> {
        fn visit(
            command: &clap::Command,
            path: &mut Vec<String>,
            shapes: &mut HashMap<Vec<String>, HashSet<String>>,
        ) {
            let mut flags = HashSet::new();
            for argument in command.get_arguments() {
                if let Some(long) = argument.get_long() {
                    flags.insert(format!("--{long}"));
                }
                // A hidden alias (`--host` for `--machine`) still works, so docs may show it.
                for alias in argument.get_all_aliases().into_iter().flatten() {
                    flags.insert(format!("--{alias}"));
                }
                if let Some(short) = argument.get_short() {
                    flags.insert(format!("-{short}"));
                }
            }
            shapes.insert(path.clone(), flags);
            for subcommand in command.get_subcommands() {
                for name in
                    std::iter::once(subcommand.get_name()).chain(subcommand.get_all_aliases())
                {
                    path.push(name.to_owned());
                    visit(subcommand, path, shapes);
                    path.pop();
                }
            }
        }

        let mut shapes = HashMap::new();
        visit(&Cli::command(), &mut Vec::new(), &mut shapes);
        for flags in shapes.values_mut() {
            flags.insert("--help".to_owned());
            flags.insert("-h".to_owned());
        }
        if let Some(flags) = shapes.get_mut(&Vec::new()) {
            flags.insert("--version".to_owned());
            flags.insert("-V".to_owned());
        }
        shapes
    }

    fn documented_shape(
        words: &[String],
        shapes: &HashMap<Vec<String>, HashSet<String>>,
    ) -> Option<Vec<String>> {
        let has_subcommands = |path: &[String]| {
            shapes.keys().any(|known| known.len() > path.len() && known.starts_with(path))
        };
        let mut start = 1;
        while words.get(start).is_some_and(|word| {
            matches!(word.as_str(), "--json" | "--suppress-reads" | "--help" | "--version")
        }) {
            start += 1;
        }
        if words.get(start).is_some_and(|word| !word.starts_with('-')) {
            let mut candidate = vec![words[start].clone()];
            if matches!(candidate[0].as_str(), "peer" | "host" | "hosts") {
                candidate[0] = "machine".to_owned();
            }
            if !candidate[0].split('|').any(|name| {
                let mut path = candidate.clone();
                path[0] = name.to_owned();
                shapes.keys().any(|known| known == &path)
            }) {
                return None;
            }
        }
        let command = words.iter().skip(start).take_while(|word| !word.starts_with('-'));
        let mut path = Vec::new();
        for word in command {
            let Some(candidate) = word.split('|').find(|candidate| {
                let candidate =
                    if path.is_empty() && matches!(*candidate, "peer" | "host" | "hosts") {
                        "machine"
                    } else {
                        candidate
                    };
                let mut next = path.clone();
                next.push(candidate.to_owned());
                shapes.keys().any(|known| known == &next)
            }) else {
                // Once a command still has subcommands, an unknown word is a
                // stale verb rather than a positional argument.  Positional
                // values are allowed only after reaching a leaf command.
                if has_subcommands(&path) {
                    return None;
                }
                break;
            };
            let candidate = if path.is_empty() && matches!(candidate, "peer" | "host" | "hosts") {
                "machine"
            } else {
                candidate
            };
            let mut next = path.clone();
            next.push(candidate.to_owned());
            path = next;
        }
        // A binary invocation containing only root flags (for example
        // `acpmux --version`) still belongs to the documented surface.
        Some(path)
    }

    #[test]
    fn documented_acpmux_commands_and_flags_are_in_the_clap_surface() {
        let shapes = command_shapes();
        let mut missing = Vec::new();
        for (source, text) in REMOTE_DOCS {
            for words in tokens(text, "acpmux") {
                let Some(path) = documented_shape(&words, &shapes) else {
                    missing.push(format!("{source}: {} (command)", words.join(" ")));
                    continue;
                };
                let mut flags = HashSet::new();
                flags.extend(
                    shapes.get(&Vec::new()).into_iter().flat_map(|flags| flags.iter().cloned()),
                );
                for end in 1..=path.len() {
                    flags.extend(
                        shapes
                            .get(&path[..end])
                            .into_iter()
                            .flat_map(|flags| flags.iter().cloned()),
                    );
                }
                for word in words.iter().skip(1).filter(|word| word.starts_with('-')) {
                    let flag = word.split('=').next().unwrap_or(word);
                    if flag == "--" || flag == "-" || !flags.contains(flag) {
                        missing.push(format!("{source}: {} (flag {flag})", words.join(" ")));
                    }
                }
            }
        }
        assert!(missing.is_empty(), "documented acpmux surface drifted:\n{}", missing.join("\n"));
    }

    /// `send --class`: the four classes only (`prompt_class.rs`).
    #[test]
    fn send_class_takes_one_of_the_four_classes() {
        for class in crate::prompt_class::PromptClass::ALL {
            let argv = ["acpmux", "send", "coord", "done", "--class", class.as_str()];
            assert!(Cli::try_parse_from(argv).is_ok(), "{argv:?} did not parse");
        }
        assert!(
            Cli::try_parse_from(["acpmux", "send", "coord", "x", "--class", "urgent"]).is_err()
        );
    }

    /// `session inbox`: --thread [--mark-read] reads the inbox's threads, --digest [--dry-run]
    /// drains the queue's agent messages, and the two never mix; `send --pr | --thread`.
    #[test]
    fn session_inbox_reads_threads_or_drains_the_queue() {
        use super::{Command, SessionInboxTarget, flatten};
        let parse = |argv: &[&str]| Cli::try_parse_from(argv).map(|c| flatten(c.command.unwrap()));
        let threads =
            parse(&["acpmux", "session", "inbox", "c", "--thread", "pr:1", "--mark-read"]);
        assert!(matches!(
            threads,
            Ok(Command::SessionInboxCmd(SessionInboxTarget { ref thread, unread: true, .. }))
                if thread.as_deref() == Some("pr:1")
        ));
        let all = parse(&["acpmux", "session", "inbox", "c"]);
        assert!(matches!(
            all,
            Ok(Command::SessionInboxCmd(SessionInboxTarget { thread: None, .. }))
        ));
        let digest = parse(&["acpmux", "session", "inbox", "c", "--digest"]);
        assert!(matches!(digest, Ok(Command::InboxDigest { dry_run: false, .. })));
        let dry = parse(&["acpmux", "session", "inbox", "c", "--dry-run"]);
        assert!(matches!(dry, Ok(Command::InboxDigest { dry_run: true, .. })));
        assert!(parse(&["acpmux", "session", "inbox", "c", "--thread", "t", "--digest"]).is_err());
        assert!(parse(&["acpmux", "session", "inbox", "c", "--mark-read"]).is_err());
        assert!(parse(&["acpmux", "send", "c", "x", "--pr", "12"]).is_ok());
        assert!(parse(&["acpmux", "send", "c", "x", "--thread", "rollout"]).is_ok());
        assert!(parse(&["acpmux", "send", "c", "x", "--pr", "12", "--thread", "t"]).is_err());
    }

    /// `machine dedicated [NAME] [on|off]` (old spelling `host vm-host`): the state is on or
    /// off only.
    #[test]
    fn machine_dedicated_takes_a_machine_and_on_or_off() {
        for verb in [["machine", "dedicated"], ["host", "vm-host"], ["machine", "vm-host"]] {
            for rest in [&[][..], &["on"][..], &["cloud-a", "off"][..]] {
                let argv: Vec<&str> =
                    ["acpmux"].into_iter().chain(verb).chain(rest.iter().copied()).collect();
                assert!(Cli::try_parse_from(&argv).is_ok(), "{argv:?} did not parse");
            }
            let argv: Vec<&str> =
                ["acpmux"].into_iter().chain(verb).chain(["cloud-a", "maybe"]).collect();
            assert!(Cli::try_parse_from(&argv).is_err(), "{argv:?} parsed");
        }
    }

    /// `host hold` changes a hold only for a named machine: a flag alone is refused, not
    /// taken as the listing (review of #25602).
    #[test]
    fn host_hold_needs_a_name_to_change_anything() {
        for argv in [
            &["acpmux", "host", "hold", "--release"][..],
            &["acpmux", "host", "hold", "--reason", "x"][..],
            &["acpmux", "host", "hold", "--until", "2026-10-28T23:59:59Z"][..],
            &["acpmux", "host", "hold", "m", "--release", "--reason", "x"][..],
        ] {
            assert!(Cli::try_parse_from(argv).is_err(), "{argv:?} parsed");
        }
        for argv in [
            &["acpmux", "host", "hold"][..],
            &["acpmux", "host", "hold", "m", "--release"][..],
            &["acpmux", "host", "hold", "m", "--reason", "x", "--until", "2026-10-28T23:59:59Z"][..],
        ] {
            assert!(Cli::try_parse_from(argv).is_ok(), "{argv:?} did not parse");
        }
    }

    #[test]
    fn peer_alias_still_parses_after_host_becomes_canonical() {
        let parsed = Cli::try_parse_from(["acpmux", "peer", "status"]);
        assert!(parsed.is_ok(), "peer alias stopped working");
    }

    /// docs/naming.md: `machine` is the command; `host`, `hosts` and `peer` stay hidden aliases
    /// that parse to the same command, and `place` stays an alias of `pick`.
    #[test]
    fn machine_is_canonical_and_old_spellings_parse_the_same() {
        use super::{Command, PeerCmd};
        let top = Cli::command();
        let machine = top.find_subcommand("machine").expect("acpmux machine exists");
        let aliases: Vec<&str> = machine.get_all_aliases().collect();
        for old in ["host", "hosts", "peer"] {
            assert!(aliases.contains(&old), "{old} is not an alias of machine");
        }
        assert!(machine.get_visible_aliases().next().is_none(), "old spellings must stay hidden");
        for word in ["machine", "host", "hosts", "peer"] {
            for (verb, want_build) in [("pick", false), ("place", false), ("pick", true)] {
                let mut argv = vec!["acpmux", word, verb];
                if want_build {
                    argv.push("--build");
                }
                match Cli::try_parse_from(&argv).map(|cli| cli.command) {
                    Ok(Some(Command::Host(PeerCmd::Place { build }))) => {
                        assert_eq!(build, want_build, "{argv:?}")
                    }
                    _ => panic!("{argv:?} is not machine pick"),
                }
            }
            let argv = ["acpmux", word, "status"];
            assert!(
                matches!(
                    Cli::try_parse_from(argv).map(|cli| cli.command),
                    Ok(Some(Command::Host(PeerCmd::Status { .. })))
                ),
                "{argv:?} is not machine status"
            );
        }
    }

    /// `--machine` is the flag; `--host` stays a hidden alias (and `dispatch --target`), with the
    /// same value grammar (`auto`, `auto-build`, `local`, NAME).
    #[test]
    fn machine_flag_and_host_alias_parse_the_same() {
        for flag in ["--machine", "--host"] {
            for value in ["auto", "auto-build", "local", "box"] {
                for argv in [
                    vec!["acpmux", "new", flag, value, "-m", "claude", "hi"],
                    vec!["acpmux", "ensure", "lane", flag, value],
                    vec!["acpmux", "dispatch", "brief.md", flag, value],
                    vec!["acpmux", "ls", flag, value],
                    vec!["acpmux", "session", "move", "chat", flag, value],
                    vec!["acpmux", "session", "start", "lane", flag, value],
                ] {
                    assert!(Cli::try_parse_from(&argv).is_ok(), "{argv:?} did not parse");
                }
            }
        }
        assert!(Cli::try_parse_from(["acpmux", "dispatch", "brief.md", "--target", "box"]).is_ok());
        let help = Cli::command().find_subcommand_mut("new").unwrap().render_help().to_string();
        assert!(
            help.contains("--machine <MACHINE>"),
            "new --help does not show --machine:\n{help}"
        );
        assert!(!help.contains("--host <"), "new --help still lists --host:\n{help}");
    }

    /// remote-ergo's fifth walk: "`acpmux daemon stop` fails with "unrecognized subcommand" and
    /// no hint, but the command is `daemon shutdown`. Anyone who knows `session stop` will guess
    /// "stop"."
    #[test]
    fn daemon_stop_is_daemon_shutdown_and_help_says_so() {
        use super::{Command, flatten};
        for (argv, want_end_agents) in [
            (&["acpmux", "daemon", "stop"][..], false),
            (&["acpmux", "daemon", "stop", "--end-agents"][..], true),
            (&["acpmux", "--json", "daemon", "stop", "--keep-agents"][..], false),
        ] {
            let cli = Cli::try_parse_from(argv).unwrap_or_else(|e| panic!("{argv:?}: {e}"));
            match cli.command.map(flatten) {
                Some(Command::Shutdown { end_agents, .. }) => {
                    assert_eq!(end_agents, want_end_agents, "{argv:?}")
                }
                _ => panic!("{argv:?} is not daemon shutdown"),
            }
        }
        // `daemon --help` lists it on shutdown's line: `[aliases: stop]`.
        let help = Cli::command().find_subcommand_mut("daemon").unwrap().render_help().to_string();
        let line = help.lines().find(|l| l.trim_start().starts_with("shutdown")).unwrap();
        assert!(line.contains("stop]"), "daemon --help does not list the stop alias:\n{help}");
    }

    #[test]
    fn stale_nested_command_is_rejected() {
        let shapes = command_shapes();
        let words = ["acpmux", "host", "statuz"].into_iter().map(str::to_owned).collect::<Vec<_>>();
        assert!(documented_shape(&words, &shapes).is_none());
    }
}

#[cfg(test)]
mod config_set_tests {
    use super::{Cli, Command};
    use clap::Parser;

    #[test]
    fn config_set_accepts_session_resource_assignment() {
        let cli =
            Cli::try_parse_from(["acpmux", "config", "--set", "session.memory_mb=6144"]).unwrap();
        match cli.command {
            Some(Command::Config { set: Some(value), .. }) => {
                assert_eq!(value, "session.memory_mb=6144")
            }
            _ => panic!("unexpected command"),
        }
    }
}
