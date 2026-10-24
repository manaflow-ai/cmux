//! The `acpmux` argument grammar. `entry` parses it; `run` executes it.

use clap::{Args, Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "acpmux", version = concat!(env!("CARGO_PKG_VERSION"), " (", env!("ACPMUX_BUILD"), ")"), about = "tmux for coding-agent harnesses: Claude Code, Codex, OpenCode, pi, Gemini", long_about = None, after_help = "Agents: `acpmux guide` (also --guide, --skill) prints the full guide for driving acpmux from a script or another agent.")]
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
    /// Send a local brief to another harness on a peer (or the least-loaded
    /// allowed host with `--host auto`) and record its identity.
    Dispatch(DispatchArgs),
    #[command(subcommand)]
    Briefs(BriefsCmd),
    /// Create a session and optionally send a first prompt. `run` is the
    /// same with --quiet: it prints only the final reply. With --worktree,
    /// --prompt-file, --report-to and --group it starts an agent on a task
    /// in one step; running it again reuses everything and sends nothing.
    #[command(alias = "new-session", alias = "run", alias = "exec")]
    New(NewArgs),
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
        /// Create on this peer when missing.
        #[arg(long)]
        host: Option<String>,
        #[arg(long)]
        cwd: Option<PathBuf>,
        #[arg(long)]
        policy: Option<String>,
        #[arg(long, short)]
        effort: Option<String>,
    },
    /// Continue a session's work on another harness: prepare a reviewed
    /// first message for a new session there, then start or discard it.
    Continue(crate::cli::handoff::ContinueArgs),
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
    /// Show or set session defaults per model family or alias: `defaults`, `defaults claude`,
    /// `defaults claude model=claude-opus-5 effort=high policy=approve-edits prefer=claude-cr,claude`,
    /// `defaults deepseek prefer=opencode,pi models.opencode=opencode-go/deepseek-v4-pro models.pi=openrouter/deepseek/deepseek-v4`.
    /// A name that is not a family or profile is an alias: `-u deepseek` then works. `key=` clears one key; `--clear` removes the entry.
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
    /// List pending permission requests across sessions, with the option ids to answer them.
    Pending,
    /// Send a prompt and stream the reply until the turn ends.
    #[command(alias = "prompt", alias = "send-keys")]
    Send {
        #[arg(required_unless_present = "status")]
        session: Option<String>,
        /// Prompt text. Reads stdin when omitted or "-".
        prompt: Vec<String>,
        /// Send this message into the running turn when the agent supports steering. On by
        /// default with --no-wait; a send that waits for the reply queues unless given this.
        #[arg(long, conflicts_with = "no_steer")]
        steer: bool,
        /// Queue behind the running turn even with --no-wait.
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
        /// named without it.
        #[arg(long, value_name = "NAME")]
        from: Option<String>,
        /// Replace your prompt still queued under KEY: a correction is never read after the
        /// order it corrects. Prints how many it replaced. A prompt whose turn started stays.
        #[arg(long, value_name = "KEY")]
        supersede: Option<String>,
    },
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
    /// List sessions on every host.
    #[command(alias = "list", alias = "list-sessions")]
    Ls {
        /// Only sessions in this state: running, ready, idle, closed, waiting.
        #[arg(long)]
        status: Option<String>,
        /// Only sessions with a pending permission request.
        #[arg(long)]
        pending: bool,
        /// Only sessions carrying this tag (key or key=value).
        #[arg(long)]
        tag: Option<String>,
    },
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
        /// Replace the dashboard token now: the old link, `ws://` peers that
        /// were given it and open dashboard connections stop working.
        #[arg(long)]
        rotate_token: bool,
    },
    /// Remote daemons: add, ls, rm.
    #[command(subcommand, alias = "hosts")]
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
    /// Everything else about one session: info, cancel, stop, rename, fork, set, allow, deny, answer, export, import, tail.
    #[command(subcommand, alias = "s")]
    Session(SessionCmd),
    /// This machine as a hand of a Cloud Chief: pair, run, status.
    #[command(subcommand)]
    Hand(crate::hand::HandCmd),
    /// The daemon: run, status, shutdown, config, harnesses, reload, models, schema.
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
    Schema,
    #[command(hide = true)]
    Models {
        #[arg(long)]
        refresh: bool,
    },
    #[command(hide = true)]
    Info { session: String },
    #[command(hide = true)]
    Cancel { session: String },
    #[command(hide = true, alias = "kill-session")]
    Kill {
        session: String,
        #[arg(long)]
        purge: bool,
    },
    #[command(hide = true)]
    RestartAgent { session: String },
    #[command(hide = true)]
    ResumeQueue { session: String },
    #[command(hide = true, alias = "rename-session")]
    Rename { session: String, new_name: String },
    #[command(hide = true)]
    Fork {
        session: String,
        #[arg(long, short)]
        name: Option<String>,
        #[arg(long)]
        cwd: Option<PathBuf>,
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
    Status,
    /// `daemon start`: status, starting a daemon first when none runs.
    #[command(hide = true)]
    DaemonStart { person_key_fd: Option<i32> },
    #[command(hide = true, alias = "kill-server")]
    Shutdown {
        /// Accepted for callers of older builds; hosted agents keep running anyway.
        #[arg(long, hide = true, conflicts_with = "end_agents")]
        keep_agents: bool,
        /// End every agent process too, hosted agents and their hosts included.
        #[arg(long)]
        end_agents: bool,
    },
    #[command(hide = true)]
    Config,
    #[command(subcommand, hide = true)]
    Peer(PeerCmd),
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
    /// Host name, `auto` for least-loaded placement, or `local`.
    #[arg(long, long_alias = "target", default_value = "auto")]
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
pub enum BriefsCmd {
    #[command(alias = "list")]
    Ls {
        #[arg(long)]
        status: Option<String>,
        #[arg(long, default_value_t = 100)]
        limit: usize,
    },
    Steer {
        brief_id: String,
        text: Vec<String>,
    },
    Report {
        brief_id: String,
        summary: Vec<String>,
        #[arg(long, default_value = "reported")]
        status: String,
    },
}

#[derive(Subcommand)]
pub enum HarnessCmd {
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
    },
    /// Sign in to a harness with its own ACP sign-in (or `claude auth login`
    /// for Claude Code). `--status` checks it; `--list` shows the methods.
    Login {
        id: String,
        /// The sign-in method id (default: the harness's first browser or
        /// terminal sign-in).
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
pub enum SecretCmd {
    /// Store a value for ID's env KEY (Keychain on macOS, secret-tool
    /// elsewhere) and write `KEY = { keychain = "cmux-harness/ID/KEY" }` into
    /// the profile file. Reads a hidden prompt, or stdin; never prints it.
    Set { id: String, key: String },
}

#[derive(Subcommand)]
pub enum SessionCmd {
    /// Show session details.
    Info { session: String },
    /// Cancel the running turn.
    Cancel { session: String },
    /// Stop the agent process. The session stays resumable.
    #[command(alias = "kill")]
    Stop {
        session: String,
        /// Also delete the log.
        #[arg(long)]
        purge: bool,
    },
    /// Restart the agent process in the same conversation: now when the
    /// session is between turns, else when its turn ends (never cancelled).
    /// It then runs the installed version and gets a new caller token (after
    /// a daemon restart left it the earlier daemon's).
    Restart { session: String },
    /// Rename a session.
    Rename { session: String, new_name: String },
    /// Run the queued prompts a failed turn held. An agent or a script may resume a
    /// queue; only answering a permission or a question needs the cmux app.
    Resume { session: String },
    /// Fork a session into a new one that shares the history so far.
    Fork {
        session: String,
        #[arg(long, short)]
        name: Option<String>,
        #[arg(long)]
        cwd: Option<PathBuf>,
    },
    /// Change mode, model, a config option, or the permission policy: key=value.
    Set { session: String, assignment: String },
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
    /// workspace's, the settings' or the default (16); setting takes the app or a parent session.
    Limits {
        session: String,
        /// Most sub-sessions running at once (1 to 1000).
        #[arg(long, value_parser = clap::value_parser!(u32).range(1..=1000), conflicts_with = "clear")]
        max: Option<u32>,
        /// Drop the session's own value.
        #[arg(long)]
        clear: bool,
    },
    /// One line per turn.
    History {
        session: String,
        #[arg(long, short = 'n', default_value_t = 20)]
        limit: usize,
    },
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
    /// Daemon status, hosts, and the web URL.
    Status,
    /// Start the daemon unless one runs, wait until it accepts clients, and print its status.
    Start {
        /// Read this launch's person key (64 hex characters, one line) from
        /// this descriptor (0: stdin) and hand it to the daemon it starts,
        /// once that daemon is not dumpable. Only the cmux app's own ssh exec
        /// or VM provisioning passes it; refused while a daemon runs.
        #[arg(long)]
        person_key_fd: Option<i32>,
    },
    /// Stop the daemon. Hosted agents keep running for the next daemon to
    /// adopt (a restart or an update); pooled hosts end. `--end-agents` ends
    /// every agent process too, agent hosts included, returns once they all
    /// exited, and fails naming any host left.
    #[command(alias = "kill-server")]
    Shutdown {
        /// Accepted for callers of older builds, where a plain shutdown ended
        /// the agents; hosted agents keep running anyway.
        #[arg(long, hide = true, conflicts_with = "end_agents")]
        keep_agents: bool,
        /// End every agent process too, hosted agents and their hosts included.
        #[arg(long)]
        end_agents: bool,
    },
    /// Print the config path and contents.
    Config,
    /// Show configured harnesses with their family and defaults.
    Harnesses,
    /// Reload catalog configuration without stopping sessions.
    Reload,
    /// Print the RPC schema (methods, notifications, types, exit codes) as JSON.
    Schema,
    /// Every model id each harness declares or reports (`provider/model` for OpenCode and pi).
    Models {
        /// Forget the reported catalogs and probe every harness again now.
        #[arg(long)]
        refresh: bool,
    },
}

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
    Setup {
        /// ssh target, e.g. cmux-lawrence or user@host
        host: String,
        /// Peer name (default: the host's first label).
        #[arg(long)]
        name: Option<String>,
        /// Port the remote daemon listens on (loopback; tunnelled over ssh).
        #[arg(long, default_value_t = 47811)]
        port: u16,
    },
    /// Copy this binary to an ssh peer (or every one with --all) and restart
    /// its daemon. The previous binary is kept and put back when the
    /// restarted daemon does not answer with the new build; a daemon under a
    /// hand-written acpmux unit is moved to acpmux.service, agents kept.
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
    /// Revoke a ticket, or a paired machine by id or name; its open
    /// connections close at once.
    Revoke { id: String },
}

#[derive(Args)]
pub struct NewArgs {
    /// A preset from `acpmux preset`: harness plus model, effort, policy, env. `-m` and `-e` still win.
    #[arg(long, short)]
    pub preset: Option<String>,
    /// Create the session on this peer (see `acpmux host ls`). `--cwd` is then a remote path.
    #[arg(long)]
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
    /// Optional first prompt.
    pub prompt: Vec<String>,
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
    /// Read the first prompt from this file (after any prompt words), now; a
    /// missing or empty file fails before anything starts.
    #[arg(long, value_name = "FILE")]
    pub prompt_file: Option<PathBuf>,
    /// Tell the new session that this session started it and how to report back.
    #[arg(long, value_name = "SESSION")]
    pub report_to: Option<String>,
    /// Show the session in the cmux app's sidebar, in this workspace group
    /// (made when missing). Runs `cmux agent open` on this machine.
    #[arg(long, value_name = "GROUP")]
    pub group: Option<String>,
    /// When a session named --name already exists, use it instead of failing;
    /// the first prompt is not sent to it again.
    #[arg(long)]
    pub reuse: bool,
}

/// Map the grouped spellings onto the flat handlers.
pub fn flatten(c: Command) -> Command {
    match c {
        Command::Session(sc) => match sc {
            SessionCmd::Info { session } => Command::Info { session },
            SessionCmd::Cancel { session } => Command::Cancel { session },
            SessionCmd::Stop { session, purge } => Command::Kill { session, purge },
            SessionCmd::Restart { session } => Command::RestartAgent { session },
            SessionCmd::Rename { session, new_name } => Command::Rename { session, new_name },
            SessionCmd::Resume { session } => Command::ResumeQueue { session },
            SessionCmd::Fork { session, name, cwd } => Command::Fork { session, name, cwd },
            SessionCmd::Set { session, assignment } => Command::Set { session, assignment },
            SessionCmd::Allow { session, option } => Command::Allow { session, option },
            SessionCmd::Deny { session } => Command::Deny { session },
            SessionCmd::Answer { session, answer } => Command::Answer { session, answer },
            SessionCmd::Export { session, dest } => Command::Export { session, dest },
            SessionCmd::Import { path, name } => Command::Import { path, name },
            SessionCmd::Transfer { session, to, cwd, name, interrupt } => {
                Command::Transfer { session, to, cwd, name, interrupt }
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
            SessionCmd::Rules { session, rules, clear } => {
                Command::RulesCmd { session, rules, clear }
            }
            SessionCmd::History { session, limit } => Command::History { session, limit },
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
            DaemonCmd::Status => Command::Status,
            DaemonCmd::Start { person_key_fd } => Command::DaemonStart { person_key_fd },
            DaemonCmd::Shutdown { keep_agents, end_agents } => {
                Command::Shutdown { keep_agents, end_agents }
            }
            DaemonCmd::Config => Command::Config,
            DaemonCmd::Harnesses => Command::Harnesses,
            DaemonCmd::Reload => Command::Reload,
            DaemonCmd::Schema => Command::Schema,
            DaemonCmd::Models { refresh } => Command::Models { refresh },
        },
        Command::Host(pc) => Command::Peer(pc),
        Command::Router(RouterCmd::Serve) => Command::Router(RouterCmd::Serve),
        other => other,
    }
}

#[derive(Subcommand)]
pub enum RouterCmd {
    /// Start the phase-one local router listeners.
    Serve,
}
