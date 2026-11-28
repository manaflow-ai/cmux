//! The `acpmux` argument grammar. `entry` parses it; `run` executes it.

use clap::{Args, Parser, Subcommand};
use std::path::PathBuf;

pub use crate::cli::command_harness::{CodexRuntimeCmd, HarnessCmd, SecretCmd};
pub use crate::cli::command_host::{PeerCmd, TicketCmd};
pub use crate::cli::command_new::NewArgs;
pub use crate::cli::command_session::{
    AutoSettleMode, InboxArgs, InboxCmd, ListenCmd, SendNotice, SendRelay, SendThread, SessionCmd,
    SessionInboxOpts, SessionInboxTarget,
};
pub use crate::cli::task::BriefsCmd;

#[derive(Args, Debug, Clone, PartialEq, Eq)]
pub struct AppOpenArgs {
    /// The existing acpmux session to open in cmux.
    pub session: String,
    /// App-owned flags such as --target, --host, --focus or --group.
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub options: Vec<String>,
}

/// `session place-set`: where an existing chat runs, from the place menu's choices.
#[derive(Args, Debug, Clone, PartialEq, Eq)]
pub struct PlaceSessionArgs {
    /// The chats to place (ids or names).
    #[arg(required = true)]
    pub sessions: Vec<String>,
    /// Auto (nothing moves now), cloud (a fresh cloud machine) or machine (move there, stay).
    #[arg(long, value_parser = ["auto", "cloud", "machine"], required_unless_present_any = ["undo", "status"])]
    pub mode: Option<String>,
    /// With `--mode machine`: the machine.
    #[arg(long, value_name = "MACHINE")]
    pub machine: Option<String>,
    /// With `--mode machine`: run the chat in this folder there (as `session move --cwd`).
    #[arg(long, value_name = "PATH")]
    pub cwd: Option<String>,
    /// The reason the chat's move line gives (default: you chose it).
    #[arg(long)]
    pub why: Option<String>,
    /// Go on although the move leaves something behind (a localhost server, files outside the
    /// repo, an ssh tunnel); without it the move lists them and does nothing.
    #[arg(long, short = 'y')]
    pub yes: bool,
    /// Move back to where the chat's last move came from. Ask the machine the chat is on now.
    #[arg(long, conflicts_with_all = ["mode", "status"])]
    pub undo: bool,
    /// Say where each chat is pinned and where a move stands; change nothing.
    #[arg(long, conflicts_with = "mode")]
    pub status: bool,
}

/// `session rebalance`: one pass of the lane rebalancer on this host (`crate::rebalance`).
#[derive(Args, Debug, Clone, PartialEq, Eq)]
pub struct RebalanceArgs {
    /// Say what would move and where, and change nothing.
    #[arg(long)]
    pub dry_run: bool,
    /// Move even while the registry's lane_overflow.rebalance.enabled is off.
    #[arg(long, conflicts_with = "dry_run")]
    pub force: bool,
    /// The most sessions this pass moves (the registry's max_moves, else 4).
    #[arg(long, value_name = "N")]
    pub max_moves: Option<usize>,
    /// The longest each move waits for a turn that started meanwhile to end, in seconds.
    #[arg(long, value_name = "SECS", default_value_t = 60)]
    pub timeout: u64,
    /// Move a receipt's session back where it came from (the id a pass printed, in
    /// rebalance.jsonl).
    #[arg(long, value_name = "RECEIPT", conflicts_with_all = ["dry_run", "force", "max_moves"])]
    pub undo: Option<String>,
    /// Run the pass for a peer host from this hub: its sessions read with `session info`, each
    /// moved with `session move HOST/ID` (the registry switch is read for that host).
    #[arg(long, value_name = "HOST", conflicts_with = "undo")]
    pub machine: Option<String>,
}

/// `session move` (and its flat spelling `move-sessions`): which chats move, and where.
#[derive(Args, Debug, Clone, PartialEq, Eq)]
pub struct MoveSessionsArgs {
    /// The chats to move (ids or names). Use HOST/CHAT for a chat on another hub machine,
    /// with --machine local to bring it here. Omit with --all-idle.
    #[arg(required_unless_present = "all_idle")]
    pub sessions: Vec<String>,
    /// The machine to move them to, or `auto`: `machine pick`'s choice among your machines
    /// (never a reserved one), one machine per checkout. `--host` still works.
    #[arg(
        long = "machine",
        alias = "host",
        value_name = "MACHINE",
        required_unless_present = "abort"
    )]
    pub host: Option<String>,
    /// Every open chat here that is between turns.
    #[arg(long, conflicts_with = "sessions")]
    pub all_idle: bool,
    /// Stop a running turn at once, even mid tool call. Without it a running turn moves with
    /// the chat: the move waits for its tool call in flight to end, and the turn goes on there.
    #[arg(long, conflicts_with = "after_turn")]
    pub interrupt: bool,
    /// Let a running turn end on its own, then move: nothing is stopped or refused while it
    /// runs, and prompts sent meanwhile move with the chat.
    #[arg(long)]
    pub after_turn: bool,
    /// With --after-turn: the longest the move waits for a running turn to end, in seconds;
    /// past it the move gives up (non-zero), naming the chat and the step.
    #[arg(long, value_name = "SECS", default_value_t = 600)]
    pub timeout: u64,
    /// Move a chat whose checkout has uncommitted changes; they stay on this machine.
    #[arg(long)]
    pub leave_dirty: bool,
    /// Carry a chat's uncommitted changes with it: tracked edits, deletions and untracked files
    /// that are not ignored arrive uncommitted in its worktree there. Likely secrets (`.env`,
    /// keys) stay on this machine.
    #[arg(long, conflicts_with = "leave_dirty")]
    pub carry_changes: bool,
    /// Run the moved chats in this folder on the machine, as it is there: no worktree is made
    /// and no branch pushed. For a folder outside this machine's home.
    #[arg(long, value_name = "PATH")]
    pub cwd: Option<String>,
    /// Say where each chat would go and change nothing.
    #[arg(long)]
    pub dry_run: bool,
    /// The machine the chats are on, when not this one: this machine drives the move over
    /// ssh to it and to the target, so two machines that cannot reach each other trade
    /// chats. With it, `--machine local` brings them here.
    #[arg(long, value_name = "MACHINE")]
    pub from: Option<String>,
    /// Copy however long the link takes: the chat keeps running while its history is copied,
    /// and only the last few records move frozen. Without it a machine whose copy is estimated
    /// at more than two hours is passed over (`auto`) or refused.
    #[arg(long)]
    pub slow_ok: bool,
    /// End a move of the named chats whose client is gone (a `move` that died or lost its
    /// daemon), now instead of after the five-minute lease: one not copied whole is given back
    /// here, one whose target took it is committed there. One whose target cannot say stays
    /// frozen, and this says why.
    #[arg(long, conflicts_with_all = ["all_idle", "dry_run", "slow_ok"])]
    pub abort: bool,
    /// With --abort: give the chat back here even though its move's target cannot say whether
    /// it took it, once the chat was offered back (`session info` shows `move undecided`, about
    /// ten minutes after the move's client went away). If the target did take it and comes back,
    /// it holds a second copy.
    #[arg(long, requires = "abort")]
    pub take_back: bool,
    /// Start the chats on the machine from this machine's copy of them, for a machine that does
    /// not answer: their transcript (the newest records kept here) and name, in a new chat
    /// there. Name each as MACHINE/CHAT, or pass --from MACHINE. The chat on the dead machine is
    /// left as it is.
    #[arg(long, conflicts_with_all = ["all_idle", "interrupt", "after_turn", "carry_changes", "leave_dirty"])]
    pub from_snapshot: bool,
    /// Land the chats on the machine's harness HARNESS instead of the one named like theirs
    /// here: one that runs the same agent (a `claude-sr2` chat onto a machine that has only
    /// `claude`). The machine refuses a harness for another agent, or one it does not have.
    #[arg(long = "as", value_name = "HARNESS", conflicts_with = "from_snapshot")]
    pub as_harness: Option<String>,
}

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

/// Whether the engine accepts this root command name or alias.
pub fn owns_word(word: &str) -> bool {
    use clap::CommandFactory as _;
    Cli::command().find_subcommand(word).is_some() || matches!(word, "stop" | "--skill" | "--guide")
}

#[cfg(test)]
mod agent_front_door_tests {
    use super::owns_word;

    #[test]
    fn engine_root_aliases_share_the_command_grammar() {
        for word in ["ls", "list-sessions", "grep", "prompt", "session", "pending", "bg", "notices"]
        {
            assert!(owns_word(word), "missing engine word {word}");
        }
        assert!(!owns_word("not-a-command"));
    }
}

/// Clap derives the canonical-name lookup; these are the additional root spellings it accepts.
pub(super) mod aliases {
    macro_rules! root_aliases {
        ($($command:ident => [$($alias:literal),+]),+ $(,)?) => {
            $(pub(in crate::cli) const $command: &[&str] = &[$($alias),+];)+

            pub(in crate::cli) const GROUPS: &[&[&str]] = &[$($command),+];
        };
    }

    root_aliases! {
        RESOLVE => ["find"],
        WHO_ELSE => ["whoelse", "overlap"],
        LEDGER => ["cost", "spend"],
        NEW => ["new-session", "run", "exec"],
        WAIT => ["wait-for"],
        SKILL => ["guide"],
        PRESET => ["presets"],
        LAST => ["reply"],
        SEND => ["prompt", "send-keys"],
        INBOX => ["team-inbox"],
        LS => ["list", "list-sessions"],
        ATTACH => ["a"],
        MACHINE => ["host", "hosts", "peer"],
        PROCESS => ["ps"],
        WORKTREE => ["wt"],
        SESSION => ["s"],
        DAEMON => ["d"],
        KILL => ["kill-session"],
        RENAME => ["rename-session"],
        SHUTDOWN => ["kill-server"],
        SEARCH => ["grep"],
        TAIL => ["events", "log", "logs"],
    }
}

#[derive(Subcommand)]
#[allow(clippy::large_enum_variant)] // parsed once per process and matched at once; boxing buys nothing
pub enum Command {
    /// Run a task on several models in separate worktrees and compare the reviewer's winner.
    #[command(subcommand)]
    Race(crate::cli::race::RaceCmd),
    /// Fork a Cloud machine N ways, one copy-on-write machine per harness, and keep one.
    #[command(subcommand)]
    ForkRun(crate::cli::fork_run::ForkRunCmd),
    /// `gh` for an agent on a machine the person added: the GitHub broker's actions, run by the
    /// Mac that lends this machine its login (`cli/gh_shim.rs`).
    #[command(hide = true, disable_help_flag = true)]
    Gh {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// Block until a pull request's checks finish (or it merges), sharing one GitHub poller with
    /// every other waiter on this machine. Exit 0 green or merged, 1 failing or closed, 3
    /// timeout, 4 head moved off --sha (`cli/pr_wait.rs`).
    #[command(name = "pr-wait")]
    PrWait(crate::cli::pr_wait::PrWaitArgs),
    /// One GitHub read of a repos/OWNER/REPO/... path through this machine's one poller: a kept
    /// answer while it is fresh, a conditional read (a 304 costs no quota) when not, the kept
    /// answer marked stale when the budget is spent. Prints the body (`cli/gh_read.rs`).
    #[command(name = "gh-read")]
    GhRead(crate::cli::gh_read::GhReadArgs),
    /// Run another person's agent's accepted forum `run` ask: one command at a repo's pushed ref,
    /// here when light, through the scheduler (cmux-ci) when heavy; prints the result as JSON,
    /// `{exit, tail, artifacts}`. A refused ask exits 7 with its reason (`run_ask.rs`).
    #[command(name = "run-ask")]
    RunAsk {
        /// The ask's JSON as the forum serves it, from a file, or - for stdin.
        file: String,
    },
    /// Send a local brief to another harness on a machine (or the least-loaded
    /// allowed machine with `--machine auto`) and record its identity.
    Dispatch(DispatchArgs),
    /// Start and inspect background tasks owned by this agent session.
    #[command(subcommand)]
    Bg(crate::cli::bg::BgCmd),
    /// Read the current session's inbox notices and message threads.
    Notices {
        /// A session name or id when run by the person; defaults to this agent session.
        session: Option<String>,
        /// Read one thread, marking it read when --mark-read is given.
        #[arg(long)]
        thread: Option<String>,
        #[arg(long, requires = "thread")]
        mark_read: bool,
    },
    /// Open a session through the cmux app's existing workspace action.
    Open(AppOpenArgs),
    /// Open a session as a tab through the cmux app's existing tab action.
    #[command(name = "open-tab")]
    OpenTab(AppOpenArgs),
    /// Task briefs: list, steer and report work tracked by the daemon.
    #[command(subcommand)]
    Briefs(BriefsCmd),
    /// Give a session here a task, end one with its result in one call, list a chat's tasks.
    #[command(subcommand)]
    Task(crate::cli::task::TaskCmd),
    /// Find the session an agent link (a PR footer's cmux.com/deeplink/agent?... or
    /// cmux://agent/...), session id, harness session id or name names, here or on a peer, and
    /// print its host, ids, harness, model, folder, lane, pull requests, last turn and link.
    #[command(aliases = aliases::RESOLVE)]
    Resolve {
        /// The link, an id, `HOST/NAME`, a name, a spoken handle, a bead id, or `@` for this session.
        query: String,
    },
    /// Who else works on these files: the other live and recent sessions, here and on peers, that
    /// read or edited them, share this worktree or branch, or work on the same topic. With no
    /// files, what the session this shell runs in edited lately.
    #[command(name = "who-else", aliases = aliases::WHO_ELSE)]
    WhoElse(crate::cli::who_else::WhoElseArgs),
    /// Byte channels between agents, here or on a peer: `listen SERVICE` prints each channel's
    /// bytes, `open [HOST] SERVICE` sends stdin and prints what comes back, like netcat.
    #[command(subcommand)]
    Channel(crate::cli::channel::ChannelCommand),
    /// What turns on this machine cost, whatever harness ran them: totals, then one line per
    /// repository, pull request, day, person, workspace, vendor, model or account.
    #[command(aliases = aliases::LEDGER)]
    Ledger(crate::cli::ledger::LedgerArgs),
    /// The harness-magic scorecard of this machine's turns: tokens and leo-units per settled pull
    /// request, steering rate, time to the first useful result, firstModelMs, requests per turn,
    /// cache-hit ratio and every harnessMagic counter, by the features the turns ran with.
    Scorecard(crate::cli::scorecard::ScorecardArgs),
    /// Link a session to the tracker beads it works on (`bd` ids), unlink them, list them.
    #[command(subcommand)]
    Bead(crate::cli::beads::BeadCmd),
    /// Create a session and optionally send a first prompt. `run` is the
    /// same with --quiet: it prints only the final reply. With --worktree,
    /// --prompt-file, --report-to and --group it starts an agent on a task
    /// in one step; running it again reuses everything and sends nothing.
    #[command(aliases = aliases::NEW)]
    New(Box<NewArgs>),
    /// Block until a session resolves: its turn ends or it needs a permission
    /// answer. Returns on the first one unless --all. Exit 0 when a turn
    /// ended, 2 when a permission is waiting, 3 on timeout.
    #[command(aliases = aliases::WAIT)]
    Wait {
        /// Session names or ids. Every running session on every host when omitted.
        sessions: Vec<String>,
        /// Give up after this many seconds (exit 3). Default an hour, as `pr-wait`'s: no wait an
        /// agent arms sleeps forever, so a hung turn or a lost event wakes it to look again.
        #[arg(long, default_value_t = crate::cli::orchestrate::WAIT_BOUND_S)]
        timeout: u64,
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
        #[arg(long, short, visible_alias = "harness")]
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
        /// With --json, print the whole record, with the command, tool and option catalogs that
        /// `--json` leaves out.
        #[arg(long)]
        full: bool,
    },
    /// Continue a session's work on another harness: prepare a reviewed
    /// first message for a new session there, then start or discard it.
    Continue(crate::cli::handoff::ContinueArgs),
    /// Retry a session's failed last turn now, in the same session (a waiting retry fires).
    Retry(crate::cli::retry::RetryArgs),
    /// One turn per turn: prompt preview, status, tools, tokens, wall time, and how much of it
    /// went to getting the prompt to the agent (START), to the agent holding it behind its own
    /// work or a compaction (QUEUED, `b` busy or `c` compacting), and to the model's first
    /// output (MODEL).
    History {
        session: String,
        #[arg(long, short = 'n', default_value_t = 20)]
        limit: usize,
    },
    /// Search prompts and replies in every session here and on this machine's peers.
    #[command(aliases = aliases::SEARCH)]
    Search {
        /// Words to find together in one prompt or reply, in any case or order.
        #[arg(required = true)]
        query: Vec<String>,
        /// At most this many matching messages, newest first.
        #[arg(long, short = 'n', default_value_t = 20, value_parser = clap::value_parser!(u32).range(1..=200))]
        limit: u32,
    },
    /// Run one prompt on several harnesses, one after another, and compare.
    Compare {
        /// HARNESS[/MODEL] per run: -m claude -m codex/gpt-5.5 …
        #[arg(long = "model", short = 'm', visible_alias = "harness", required = true)]
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
    #[command(aliases = aliases::SKILL)]
    Skill,
    /// A sub-agent's job on a fork of this machine: the job JSON on stdin, its frames on
    /// stdout (`placement/sub_fork_run.rs`; the parent's runner starts it over ssh).
    #[command(name = "sub-fork-job", hide = true)]
    SubForkJob,
    /// Run a heavy build or test on a fork of this Cloud machine (RFD 0144 piece 3,
    /// `placement/run_vm.rs`): its output streams here, its file changes come back. Runs here
    /// when AutoCloud is off, this is no Cloud machine, or the command is not a heavy class.
    #[command(name = "run-vm", hide = true)]
    RunVm {
        /// The program an exec router shim stands in for (`placement/exec_router.rs`): the
        /// words after `--` are then its arguments, not a shell command.
        #[arg(long, value_name = "PROGRAM")]
        shim: Option<String>,
        /// The shell command (or, with `--shim`, the program's arguments), after `--`.
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        command: Vec<String>,
    },
    /// The exec router (`placement/exec_router.rs`): where each heavy command an agent, a
    /// helper or their subprocesses ran went, and why. Not `exec`: that is `new`'s alias.
    #[command(name = "exec-router", subcommand)]
    Exec(ExecCmd),
    /// A `gh run view` log, served from or kept in this machine's shared cache of finished CI
    /// logs (harness magic `sharedCache`, `ci_log_cache.rs`); the Bash hook puts it before `gh`.
    #[command(name = "ci-log-cache", hide = true)]
    CiLogCache {
        /// The `gh` command, after `--`.
        #[arg(trailing_var_arg = true, allow_hyphen_values = true, required = true)]
        command: Vec<String>,
    },
    /// Execute one authenticated Cloud trigger operation from a JSON stdin envelope.
    #[command(name = "trigger-chat", hide = true)]
    TriggerChat {
        /// Exact wire protocol required by the guest bridge.
        #[arg(long, default_value = "trigger-chat-v1")]
        protocol: String,
        /// Read the guest principal envelope from this file descriptor (fd 0 only).
        #[arg(long = "principal-fd", default_value_t = 0)]
        principal_fd: i32,
    },
    /// Print the protocol capability ids this build serves, one per line (`--json`: an object).
    /// Needs no daemon: the app bundle records them for the web agent pane.
    Capabilities,
    /// How this Cloud machine's agents reach models (base URLs, placeholder keys) and whether it
    /// holds any provider login. Names and verdicts only, never a value. Needs no daemon.
    #[command(name = "machine-auth")]
    MachineAuth,
    /// Show or set presets: `preset`, `preset deepseek harness=opencode model=opencode-go/deepseek-v4-pro effort=low`,
    /// `preset omx harness=codex 'env.CODEX_HOME=${cwd}/.codex'`. `key=` clears one key; `--clear` removes the preset.
    #[command(aliases = aliases::PRESET)]
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
    #[command(aliases = aliases::LAST)]
    Last {
        session: String,
        /// How many replies, newest last.
        #[arg(long, short = 'n', default_value_t = 1)]
        count: usize,
    },
    /// List pending permission requests across sessions, and how to answer them, and the other
    /// sessions' messages a chat's Claude Code holds (`heldMessages` in --json). acpmux keeps the
    /// held messages in memory only: after a daemon restart they no longer show.
    Pending,
    /// Send a prompt and stream the reply until the turn ends.
    #[command(
        aliases = aliases::SEND,
        after_help = "A send that returns once handed off (--no-wait, an agent's send) prints one stable first line, `sent STATE id=ID to=TARGET`, where STATE is queued (in the outbox or behind the target's turn), held (in an idle receiver's inbox, read with its next turn), delivered or steered (into its running turn); the lines after it are for people. --json prints {\"ok\":true,\"state\":STATE,\"id\":ID,...}. Scripts and retry loops check the exit code, never the text.\n\nExit codes: 0 sent (every STATE above, or the reply of a send that waits), 1 any other failure, 2 usage, 3 timeout (the prompt may have been accepted: resend with --prompt-id), 4 no such session, 5 a permission refused (--on-permission fail), 7 the target refused the message at once and nothing was delivered.\n\nA name several live sessions share is refused with the exact command for each.\n\nFrom an agent session, message other sessions with the `send` tool of the `acpmux` MCP server instead of this command in a shell: one call batches several (`messages: [{to, text}, {to, file}]`) or a tag, with one result row each, and the chat draws it as message cards."
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
        /// trying again while the peer is down (`acpmux send --status ID`). The default for an
        /// agent's send and for one with --class; the person's own send waits for the reply.
        #[arg(long, conflicts_with = "wait")]
        no_wait: bool,
        /// Wait for the reply and stream it, even for an agent's send or one with --class,
        /// which otherwise return once the message is queued here. --quiet and --timeout wait too.
        #[arg(long)]
        wait: bool,
        /// Print the state of a delivery a queued send printed: queued, delivering, delivered,
        /// held or failed. With no ID, every message this daemon was handed, newest first.
        #[arg(long, value_name = "ID", num_args = 0..=1, default_missing_value = "", conflicts_with_all = ["session", "no_wait", "wait"])]
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
        /// Report prompt_stalled (exit 1) when nothing happens for this many seconds after sending; 0 disables. The default waits for the live peer.
        #[arg(long, default_value_t = 0)]
        stall: u64,
        /// Send this prompt id again (from a `daemon_closed` error): the daemon runs an id once and
        /// answers a repeat with the first run's outcome.
        #[arg(long)]
        prompt_id: Option<String>,
        /// Send it as this agent's message: messages from agents that wait for a busy session go
        /// in together as one turn, after the person's own. An agent running in acpmux is
        /// named without it; elsewhere `ACPMUX_FROM` names it. Neither is a reply address: a
        /// Claude Code chat acpmux did not start that sends with neither also starts its own
        /// `acpmux register` (macOS), so the receiver can answer once it runs the `--code` line
        /// delivered to it.
        #[arg(long, value_name = "NAME")]
        from: Option<String>,
        /// Prove a named sender (--from, ACPMUX_FROM, a notice's sender) is one this machine's
        /// owner set up: read this host's sender token from PATH (`~/.acpmux/sender-token`) and
        /// send it to the daemon, which then shows the sender as verified. ACPMUX_SENDER_TOKEN
        /// gives the token itself. Never on the command line; a wrong one sends unverified.
        #[arg(long, value_name = "PATH")]
        sender_token_file: Option<PathBuf>,
        /// Replace your prompt still queued under KEY: a correction is never read after the
        /// order it corrects. Prints how many it replaced. A prompt whose turn started stays.
        #[arg(long, value_name = "KEY")]
        supersede: Option<String>,
        /// What your message asks of the receiver: block or blocker (you cannot go on until it
        /// acts), question (you wait for its answer; the default for an agent's send that
        /// waits), result or action (work you finished, or work for it; the default for one that
        /// does not wait) or fyi. The session that started the receiver or gave it its first
        /// work sends a prompt, its own turn. Anyone else's message goes into the receiver's
        /// inbox: blockers and questions wake an idle receiver, actions only from that session,
        /// FYIs never. A send that waits and would not wake the idle receiver fails at once
        /// (exit 1, send.not_woken), and nothing is delivered.
        #[arg(long, value_name = "CLASS", value_parser = ["block", "question", "result", "fyi", "blocker", "action"])]
        class: Option<String>,
        #[command(flatten)]
        inbox: SendThread,
        #[command(flatten)]
        relay: SendRelay,
        /// Send this file with the message (repeatable): an image reaches the agent and its
        /// transcript as an image, any other file as a link to its copy. Saved owner-only on the
        /// session's machine, a peer's too. Any size and number: large ones are uploaded first.
        #[arg(long, value_name = "FILE")]
        attach: Vec<PathBuf>,
        #[command(flatten)]
        notice: Box<SendNotice>,
        /// Wait for the receiver's batch instead of waking it at once, as another agent's
        /// message does: a chat whose prompt cache lapsed takes everything that came in its
        /// window as one turn (`hub/cold_wake.rs`). For a producer outside any chat (a forum or
        /// Slack bridge, a CI notifier): it needs a sender (--from, ACPMUX_FROM or --notice),
        /// and is refused as a block, a question or a fire notice, which wake at once. Does not
        /// wait for the reply.
        #[arg(long, conflicts_with_all = ["wait", "quiet", "timeout", "tag"])]
        gather: bool,
        /// Deliver it within this long (90s, 5m, 1h): a message the receiver's inbox holds wakes
        /// the receiver by its deadline, at the latest 15 minutes for a result (an action) and
        /// 60 for an FYI (a block or a question wakes it at once). This only tightens that.
        #[arg(long, value_name = "DURATION", value_parser = crate::prompt_class::parse_within)]
        within: Option<u64>,
    },
    /// Team-scoped durable messages. Needs a team hub (`meshRelay`); on there by default.
    #[command(aliases = aliases::INBOX)]
    Inbox(InboxArgs),
    /// Listen on a teammate's agent address: read what it receives while its owner's grant
    /// lets you. Needs a team hub (`meshRelay`).
    Listen {
        #[command(subcommand)]
        command: ListenCmd,
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
    /// List sessions on every host: by default only live, named lanes, one short line each;
    /// `--json` with no filter is every session's full record.
    #[command(aliases = aliases::LS, after_help = crate::cli::ls_table::HELP)]
    Ls(crate::cli::run::LsArgs),
    /// Archive chats: off the chat lists until unarchived; `ls --archived` lists them. One
    /// archived already keeps its archive.
    Archive {
        /// Session names or ids (`host/name` for a peer's).
        #[arg(required = true)]
        sessions: Vec<String>,
    },
    /// Bring archived chats back to the lists. One that is not archived is left as it is.
    Unarchive {
        /// Session names or ids (`host/name` for a peer's).
        #[arg(required = true)]
        sessions: Vec<String>,
    },
    /// Bring a chat the lifecycle pass (or anyone) archived back in one step: unarchived,
    /// undeleted when deleted, and its log back on this disk, fetched from cloud history when it
    /// was offloaded there.
    Restore {
        /// The chat's id or name.
        session: String,
    },
    /// Open the TUI on a session, or on the session list.
    #[command(aliases = aliases::ATTACH)]
    Attach {
        session: Option<String>,
        /// Plain text stream instead of the TUI.
        #[arg(long)]
        plain: bool,
    },
    /// Run a Claude Code or Codex chat's conversation in this terminal: shows the chat's turn
    /// as it runs, then, once the chat is idle, the chat stops its agent and watches this
    /// terminal, which runs the agent's own resume command (`claude --resume ID`, `codex
    /// resume ID`). Toggle Terminal and Chat types it. Never cuts a turn off.
    ResumeHere {
        session: String,
        /// Print the resume command (with --json: `{argv, cwd, env}`) instead of running it.
        #[arg(long)]
        print: bool,
    },
    /// Be an ACP agent on stdin/stdout for an editor (Zed: `"command": "cmux",
    /// "args": ["acp", "stdio", "-m", "claude"]`). Relays to the daemon;
    /// the flags are defaults for each new session the editor creates.
    Stdio {
        /// HARNESS[/MODEL] for new sessions (`claude`, `codex/gpt-5.5`).
        #[arg(long, short, visible_alias = "harness")]
        model: Option<String>,
        /// A preset from `acpmux preset`.
        #[arg(long, short)]
        preset: Option<String>,
        #[arg(long, short)]
        effort: Option<String>,
        /// Permission policy: ask, approve-reads, approve-edits, approve-all, deny-all, review.
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
        /// The program only prints a reply and changes nothing (a test or
        /// echo program): say so at `initialize` (`asksBeforeTools`), so the
        /// agent runs under a permission policy such as a remote start's
        /// `ask`. acpmux believes it only from a harness entry of its own
        /// config. Never for a program that edits files or runs commands.
        #[arg(long)]
        prints_only: bool,
        /// The program and its arguments, after `--`.
        #[arg(trailing_var_arg = true, allow_hyphen_values = true, required = true)]
        command: Vec<String>,
    },
    /// Be an ACP agent backed by a UniiChat server (uniichat.com or your own
    /// `unii serve`), over UniiChat's own protocol: streaming, stop, images.
    /// Signs in with the token `unii login` keeps; `uniichat-agent login`
    /// makes that sign-in itself, so no `unii` program is needed. In a
    /// profile: `args = ["uniichat-agent"]`.
    UniichatAgent {
        /// `login`: sign in to the server (an email or @github, a link, a
        /// code) and keep the token where the adapter reads it.
        #[arg(value_parser = ["login"])]
        action: Option<String>,
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
        /// Open the shipped NEXT agent pane instead of the dashboard.
        #[arg(long)]
        app: bool,
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
        /// Serve the agent pane over this machine's tailnet name with HTTPS
        /// (`tailscale serve`), so a browser on another device of yours can open and
        /// sign in to it. Prints that https link; implies `--app`.
        #[arg(long)]
        tailnet: bool,
    },
    /// Machines that run sessions: add, ls, status, pick, setup, update, enroll, doctor, ticket and more.
    /// The old spellings `host`, `hosts` and `peer` still work.
    #[command(subcommand, name = "machine", aliases = aliases::MACHINE)]
    Host(PeerCmd),
    /// Bring your own harness: list, add, doctor and reload harness profile
    /// files (~/.config/cmux-next/harnesses/<id>.toml). Also `cmux harness …`.
    #[command(subcommand)]
    Harness(HarnessCmd),
    /// Forum rules: announce one, list the current ones, ack one.
    #[command(subcommand)]
    Forum(crate::cli::forum::ForumCmd),
    /// The memory mount shared by your machines (~/.cmux/memory): sync, put, get, ls, history,
    /// status, and link a harness's memory folder into it.
    #[command(subcommand)]
    Memory(crate::cli::memory::MemoryCmd),
    /// Bridge Claude Desktop, Codex Desktop and ChatGPT Desktop to each other and to cmux sessions:
    /// connect, send, inbox.
    #[command(subcommand)]
    Bridge(crate::cli::bridge::BridgeCmd),
    /// Wake a session with one message when others are done or blocked: add, ls, rm.
    #[command(subcommand)]
    Watch(crate::cli::watch::WatchCmd),
    /// Cloud triggers: on a GitHub event (CI failure, PR comment) or a signed webhook, wake a
    /// Cloud chat with a prompt: create, ls, rm.
    #[command(subcommand)]
    Trigger(crate::cli::trigger::TriggerCmd),
    /// Give the Claude desktop app, Claude Code and Codex the cmux tools: link, unlink, status.
    #[command(subcommand)]
    Desktop(crate::cli::desktop::DesktopCmd),
    /// Every chat on this device, from every harness: list, open, roots. Also `cmux chats …`.
    #[command(subcommand)]
    Chats(crate::cli::chats::ChatsCmd),
    /// Read-only local branch board (Labs > Show Preview Features). Also `cmux board --json`.
    Board,
    /// With no subcommand (`acpmux ps`): every process acpmux started on this machine and the
    /// state it keeps, with each one's owner now, session, age and state (in-use, idle,
    /// orphaned, unknown) and why, read from the processes' own marks and their hosts' locks.
    /// Subcommands: background processes agents left running (dev servers, watchers): list,
    /// show (everything one printed, live with --follow), kill, background (Ctrl-B).
    #[command(aliases = aliases::PROCESS)]
    Process(crate::cli::process::ProcessArgs),
    /// End what acpmux proves is orphaned: processes an ended agent host left behind and lock
    /// files nothing holds. A dry run unless --apply; refuses anything a live host or session
    /// still references; every end is logged with its reason in `process-kills.jsonl`.
    Gc {
        /// End them (default: only list what would be ended, and what is refused and why).
        #[arg(long)]
        apply: bool,
    },
    /// This machine's git worktrees, cleaned up after the agents that made
    /// them: list, clean (archive work only there, then remove), restore,
    /// archives.
    #[command(subcommand, aliases = aliases::WORKTREE)]
    Worktree(crate::cli::worktree::WorktreeCmd),
    /// Keep this machine's disk under budget: status, clean, why, tick (the headless pass a
    /// timer runs), install-timer. `cmux care ...` is the same.
    #[command(subcommand)]
    Care(crate::cli::care::CareCmd),
    /// Download one large file over parallel range requests (16 by default), for a path where
    /// one stream is slow (a Cloud VM's IPv4 from GitHub). Follows redirects; checks the length
    /// and, with --sha256, the hash before the file appears at -o.
    Fetch(crate::cli::fetch::FetchArgs),
    /// GitHub CI: wait for a workflow run (or a pull request's checks) with conditional reads
    /// that cost no quota while nothing changes (`cli/ci_wait.rs`).
    #[command(subcommand)]
    Ci(crate::cli::ci_wait::CiCmd),
    /// The cmux app's sidebar groups: ls, move a session's workspace into one,
    /// tidy (one group per name in a space; a dry run unless --apply).
    #[command(subcommand)]
    Group(crate::cli::group::GroupCmd),
    /// Accounts the agents here run on: sign in (again or a new one, GitHub too), sign out,
    /// switch the default, remove, list, and which providers are ready.
    #[command(subcommand)]
    Account(crate::cli::account::AccountCmd),
    /// Everything else about one session: info, cancel, stop, rename, fork, set, allow, deny, answer, export, import, tail, queue.
    #[command(subcommand, aliases = aliases::SESSION)]
    Session(SessionCmd),
    /// This machine as a hand of a Cloud Chief: pair, run, status.
    #[command(subcommand)]
    Hand(crate::hand::HandCmd),
    /// This Mac's share host: the daemon serves screen shares with no app running. status, on, off, link.
    #[command(subcommand)]
    ShareHost(crate::share_host::cli::ShareHostCmd),
    /// The daemon: run, status, start, restart, shutdown (also stop), config, harnesses, reload, models, schema.
    #[command(subcommand, aliases = aliases::DAEMON)]
    Daemon(DaemonCmd),
    /// Serve the local CodeRouter in a separate process.
    #[command(subcommand)]
    Router(RouterCmd),
    /// cmux Computer Use for one agent session: an MCP stdio server
    /// (agent_tools.rs registers it; not for people; see `cmux computer-use`).
    #[command(hide = true)]
    ComputerUseMcp,
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
    /// The agent's Cloud repository tools (this_folder, list_repos and add_repo), only on Cloud machines.
    #[command(hide = true)]
    RepoMcp,
    /// cmux's hosted MCP server with the signed-in person's tools (GitHub connectors, their own
    /// remote MCP servers): an MCP stdio server agent_tools.rs registers (not for people).
    #[command(hide = true)]
    HostedMcp,
    /// GitHub's own MCP server through the team's cmux GitHub connection, on a cmux Cloud
    /// machine: an MCP stdio server agent_tools.rs registers (not for people).
    #[command(hide = true)]
    GithubMcp,
    /// The agent's tools to message other sessions and read them (send, ls, last, info): an
    /// MCP stdio server for one agent session (agent_tools.rs registers it; not for people).
    #[command(hide = true)]
    AcpmuxMcp,
    /// The inbox relay for the Claude Code session that starts it, as an MCP stdio server with no
    /// tools (`claude_inbox_relay.rs`): acpmux's messages into that session come from its own
    /// child, so the session does not hold them (not for people).
    #[command(hide = true)]
    InboxRelay,
    /// acpmux's own agent tool servers (secrets, offers, sub-sessions, forum, acpmux) in one
    /// MCP stdio process for one agent session: `cmux mcp serve` runs it once per chat
    /// (tools_mcp.rs; not for people).
    #[command(hide = true)]
    ToolsMcp,
    // Old spellings, kept working but hidden from help. `events`, `log` and `logs` are what an
    // agent guesses for a session's events (Leo, 2026-11-21: "your thing should also be
    // acceptable input"): they run this, and say it is `session tail`.
    #[command(hide = true, aliases = aliases::TAIL)]
    Tail {
        session: String,
        #[arg(long, short = 'n', visible_alias = "tail", default_value_t = 50)]
        last: u64,
        #[arg(long, short)]
        follow: bool,
        #[arg(long)]
        since: Option<String>,
    },
    #[command(hide = true)]
    TagCmd {
        session: String,
        assignments: Vec<String>,
        #[arg(long)]
        remove: Vec<String>,
        #[arg(long)]
        ttl: Option<u64>,
    },
    #[command(hide = true)]
    UnsettleCmd { session: String },
    #[command(hide = true)]
    SessionSearch(crate::cli::session_search::SearchArgs),
    #[command(hide = true)]
    RulesCmd {
        session: String,
        rules: Option<String>,
        #[arg(long)]
        clear: bool,
    },
    #[command(hide = true)]
    LimitsCmd {
        session: String,
        #[arg(long)]
        max: Option<u32>,
        #[arg(long)]
        clear: bool,
    },
    #[command(hide = true)]
    TurnCapCmd {
        session: String,
        #[arg(long)]
        minutes: Option<u64>,
        #[arg(long)]
        off: bool,
        #[arg(long)]
        clear: bool,
    },
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
    /// A Cloud machine: make the reserved folder of its first home chat and warm an agent in it
    /// (`hub/pool/reserved.rs`). The Cloud app runs it right after keying a spare machine.
    #[command(name = "warm-home", hide = true)]
    WarmHome {
        /// Answer once the agent is ready, not when it starts.
        #[arg(long)]
        wait: bool,
        /// A harness and model the person set up, `HARNESS[:MODEL]`, warmed beside the default
        /// (personal spares; repeat for each, at most 4).
        #[arg(long = "shape", value_name = "HARNESS[:MODEL]")]
        shapes: Vec<String>,
    },
    /// The harnesses and models this machine's person used in the last week (newest first, at
    /// most 4), as `warm-home --shape` takes them: the Cloud app reads them on the Mac and warms
    /// a spare of each on the person's Cloud machine.
    #[command(name = "spare-shapes", hide = true)]
    SpareShapes,
    #[command(hide = true)]
    Info {
        session: String,
        #[arg(long, value_name = "FIELD[,FIELD…]")]
        fields: Option<String>,
    },
    #[command(hide = true)]
    Cancel { session: String },
    #[command(hide = true, aliases = aliases::KILL)]
    Kill {
        session: String,
        #[arg(long)]
        purge: bool,
        /// With `--purge`: delete now, with no grace to restore it.
        #[arg(long, requires = "purge")]
        now: bool,
        /// Set from `session stop --if-idle`; the hidden spelling takes no condition.
        #[arg(skip)]
        condition: StopIf,
        #[command(flatten)]
        close: CloseArgs,
    },
    /// `session undelete`.
    #[command(hide = true)]
    Undelete { session: String },
    /// `session deleted`.
    #[command(hide = true)]
    Deleted,
    #[command(hide = true)]
    RestartAgent { session: String },
    #[command(hide = true)]
    RouteDeath {
        session: Option<String>,
        facts: Option<PathBuf>,
        #[arg(long)]
        show_facts: bool,
    },
    #[command(hide = true)]
    PauseAgent { session: String },
    #[command(hide = true)]
    WakeAgent { session: String },
    #[command(hide = true)]
    PlaceSession(PlaceSessionArgs),
    // Built only by flattening `session hold` / `session release`; its fields carry no #[arg], so it
    // is no subcommand of its own (clap's debug build refused the positional `held` switch).
    #[command(skip)]
    SessionHold {
        session: Option<String>,
        held: bool,
        fleet: bool,
        allow: Vec<String>,
        set_allow: Option<Vec<String>>,
        reason: Option<String>,
        status: bool,
        hold_for: Option<String>,
    },
    #[command(hide = true)]
    ResumeQueue {
        session: String,
        #[arg(long)]
        open: bool,
    },
    #[command(hide = true)]
    InboxDigest {
        session: String,
        #[arg(long)]
        dry_run: bool,
    },
    #[command(hide = true, aliases = aliases::RENAME)]
    Rename {
        session: String,
        new_name: String,
        /// Rename the spoken handle.
        #[arg(long)]
        handle: bool,
        /// With --handle: set the icon too (as `acpmux icon`).
        #[arg(long, requires = "handle")]
        icon: Option<String>,
    },
    /// Set the icon every surface draws for a session (tab, sidebar row, lists, chat header, a
    /// message's sender): one emoji, an SF Symbol (`leaf.fill`, `sf:NAME`), an agent mark
    /// (`claude`), an .svg/.png/.ico file, or a URL (an image, or a site whose favicon it takes).
    /// `none` clears it; no ICON prints it. `@` is the session this shell runs in: an agent sets
    /// its own icon with no one's leave.
    #[command(
        after_help = "Examples:\n  acpmux icon @ 🥭\n  acpmux icon @ sf:leaf.fill\n  acpmux icon @ ./mark.svg\n  acpmux icon @ https://github.com\n  acpmux rename @ Mango --handle --icon 🥭\n  acpmux icon @ none"
    )]
    Icon { session: String, icon: Option<String> },
    /// A frame of the chat's page now, kept in its running turn's frames strip (cmuxterm-hq RFD
    /// 0152): `--built SOURCE` says a `cmux live` loop's build is in place (`rust`, `swift`,
    /// `chromium`, `web`), so the frame shows the swapped build, not the save before it. `@` is the
    /// chat this shell runs in. No running turn: nothing is taken.
    #[command(hide = true, after_help = "Example:\n  acpmux frame @ --built rust")]
    Frame {
        #[arg(default_value = "@")]
        session: String,
        #[arg(long, value_name = "SOURCE")]
        built: String,
    },
    /// Make a session the successor of sessions that died or moved (a rotation, a restart under a
    /// new name, a move): a message to one of them reaches it, here and through the mesh hub.
    /// Each name it takes over keeps the names that one answered to.
    #[command(
        after_help = "Examples:\n  acpmux succeed old-host/old-lane\n  acpmux succeed --session lane-b lane-a"
    )]
    Succeed {
        /// The session that takes over (default: the one this shell runs in).
        #[arg(long, default_value = "@")]
        session: String,
        /// `HOST/NAME`, or a NAME on this machine.
        #[arg(required = true)]
        names: Vec<String>,
    },
    /// Role addresses a session answers to: `goal:SLUG`, `area:NAME`, `topic:NAME`. A message
    /// to one reaches the session that claimed it last, here and through the mesh hub.
    Role {
        #[command(subcommand)]
        cmd: RoleCmd,
    },
    /// Give the session this shell runs in a stable name every machine that peers this one sends
    /// to: a Claude Code session acpmux did not start (the Claude desktop app's Code tab, a
    /// terminal `claude`). Run it from that session's own Bash tool: it delivers a one-time code
    /// into the session's inbox, and the session finishes with `acpmux register NAME --code CODE`
    /// (macOS: the daemon checks the process is Claude Code by its signature). A Codex desktop
    /// thread does not register (nothing ties a shell to its thread); start Codex with acpmux. Then `acpmux send NAME ...` reaches it through the outbox (queued and tried again
    /// while it is not running, `send --status`), and its own `acpmux send` goes out under NAME.
    /// Run it again after the session restarts (a new process gets a new token). A brand-new
    /// session registers after its first turn, once it has a transcript. Such a session's own
    /// `acpmux send` takes the first step itself, as claude-desktop-<first 8 of its session id>,
    /// so a chat that messages an agent gets the code without asking
    #[command(
        after_help = "Examples:\n  # From the desktop chat's Bash tool\n  acpmux register desktop-zoe\n  # Then, as the message it receives says\n  acpmux register desktop-zoe --code CODE\n  # From another machine\n  acpmux send --no-wait cosmic-gray/desktop-zoe 'Merged #812'\n  # In a Claude Code SessionStart and Stop hook: reachable again after a restart\n  acpmux register --renew"
    )]
    Register {
        /// The name, e.g. desktop-zoe.
        #[arg(required_unless_present = "renew")]
        name: Option<String>,
        /// The one-time code acpmux delivered into this session's inbox after a first
        /// `acpmux register NAME`: the second step, run by the session that received it.
        #[arg(long, conflicts_with = "renew")]
        code: Option<String>,
        /// For a Claude Code hook (SessionStart, Stop): hand a registered chat's new token to
        /// acpmux after Claude Code restarted with `--resume`, so its name reaches it again with
        /// no one running `register`. Silent, never fails, and delivers nothing to a chat that
        /// never registered.
        #[arg(long)]
        renew: bool,
        /// For cmux's own Claude Code hook (`cmux-tui-hook`, UserPromptSubmit): the first step
        /// with no person's step, under NAME unless the chat has a name already. Nothing when
        /// the chat is registered with this process; else a one-time code goes to the chat's
        /// inbox, as from a send. Starts no daemon, never fails (`cli/hook_register.rs`).
        #[arg(long, hide = true, conflicts_with_all = ["code", "renew"], requires = "name")]
        auto: bool,
    },
    #[command(hide = true)]
    DetachParent { session: String },
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
        /// Continue on another harness (a family or profile): the fork's agent gets the chat's
        /// conversation with its first prompt.
        #[arg(long)]
        harness: Option<String>,
        /// The model the fork runs, on --harness or the chat's own harness (MODEL or
        /// HARNESS/MODEL). A model the harness does not list fails the fork.
        #[arg(long, short)]
        model: Option<String>,
    },
    #[command(hide = true)]
    Set { session: String, assignment: String },
    #[command(hide = true)]
    Allow {
        session: String,
        option: Option<String>,
        #[arg(long)]
        standing_grant: bool,
    },
    #[command(hide = true)]
    Deny { session: String },
    #[command(hide = true)]
    Answer {
        session: String,
        #[arg(long = "answer", value_name = "QUESTION=CHOICE")]
        answer: Vec<String>,
    },
    #[command(hide = true)]
    Place {
        session: String,
        #[arg(long)]
        on: String,
        #[arg(long)]
        reason: Option<String>,
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
    /// `session move`'s flat form, also typed as `acpmux move-sessions`: the same grammar, one
    /// struct, so the two spellings cannot drift apart again.
    #[command(hide = true)]
    MoveSessions(MoveSessionsArgs),
    /// `session rebalance`'s flat form.
    #[command(hide = true)]
    Rebalance(RebalanceArgs),
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
        #[arg(long)]
        after_turn: bool,
    },
    #[command(hide = true)]
    Harnesses,
    #[command(hide = true)]
    Reload,
    #[command(hide = true)]
    Retention(RetentionArgs),
    #[command(hide = true)]
    HistoryDelete(HistoryDeleteArgs),
    #[command(hide = true)]
    HistoryOffload(HistoryOffloadArgs),
    #[command(hide = true)]
    Lifecycle(LifecycleArgs),
    #[command(hide = true)]
    TranscriptOffload(TranscriptOffloadArgs),
    #[command(hide = true)]
    Status {
        #[arg(long)]
        show_token: bool,
    },
    /// `daemon start`: status, starting a daemon first when none runs.
    #[command(hide = true)]
    DaemonStart {
        #[arg(long)]
        person_key_fd: Option<i32>,
        #[arg(long)]
        show_token: bool,
    },
    /// `daemon enroll`: give the running daemon the person key (the VM provisioning exec).
    #[command(hide = true)]
    DaemonEnroll { person_key_fd: i32 },
    #[command(hide = true)]
    DaemonRestart,
    /// `daemon stats`: the busiest callers or methods over a recent window.
    #[command(hide = true)]
    DaemonStats {
        #[arg(long, value_enum, default_value_t = crate::cli::daemon_stats::By::Caller)]
        by: crate::cli::daemon_stats::By,
        #[arg(long, default_value = "60s")]
        since: String,
        #[arg(long, default_value_t = 20)]
        top: usize,
    },
    /// `daemon felt`: the felt-latency histograms (the net graph).
    #[command(hide = true)]
    DaemonFelt,
    /// `daemon watchdog-hold`: hold the daemon's systemd watchdog for a pause.
    #[command(hide = true)]
    DaemonWatchdogHold,
    /// `daemon placement`: one tailnet placement update.
    #[command(hide = true)]
    DaemonPlacement { message: String },
    /// `daemon prune`: clear dead daemons' records (a dry run unless `apply`).
    #[command(hide = true)]
    DaemonPrune {
        #[arg(long)]
        apply: bool,
    },
    #[command(hide = true)]
    DaemonService {
        #[command(subcommand)]
        action: crate::cli::daemon_service::ServiceAction,
    },
    /// App sign-out: clear peer tails without starting an agent or daemon.
    #[command(hide = true, name = "__clear-peer-snapshots")]
    ClearPeerSnapshots,
    #[command(hide = true, aliases = aliases::SHUTDOWN)]
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
        /// `permissions.default=yolo` (yolo, standard, ask or default) for the
        /// permission mode every new chat starts in, `permissions.codex=ask` for
        /// one harness, `session.memory_mb=6144`, `session.swap_mb=2048`,
        /// `session.tasks_max=8192`, `session.sessions_tasks_max=131072`,
        /// `session.cpu_class=background`, `remote_daemon=127.0.0.1:PORT` or
        /// `lane_gh_broker=~/.cache/lane-gh-broker/broker.sock`, or on a lane machine
        /// `lane_gh_carrier=OWNER[,OWNER...]` for lane-gh over the carrier, off by default). A value the
        /// daemon would refuse to start with is refused and config.json is left as it was:
        /// `transport.wireguard=true` needs `transport.wireguardStatic` in config.json first.
        /// The hub carrier (`cmux remote ... --via-machine`) needs no setting here: a joined
        /// machine runs it on its node key.
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
    #[arg(long, short, visible_alias = "harness")]
    pub model: Option<String>,
    #[arg(long)]
    pub preset: Option<String>,
    #[arg(long)]
    pub policy: Option<String>,
    #[arg(long)]
    pub cwd: Option<PathBuf>,
}

#[derive(Subcommand)]
pub enum RoleCmd {
    /// Claim ADDRESS: every other session here gives it up.
    #[command(after_help = "Examples:\n  acpmux role claim goal:ci-linux-on-pool")]
    Claim {
        address: String,
        /// The session that claims it (default: the one this shell runs in).
        #[arg(long, default_value = "@")]
        session: String,
    },
    /// Give ADDRESS up.
    Release {
        address: String,
        #[arg(long, default_value = "@")]
        session: String,
    },
    /// Every role and successor entry the sessions here hold.
    Ls,
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
    /// Hold the running daemon's systemd watchdog until this machine resumes (or 15 minutes pass
    /// with no resume seen), so a pause of any length cannot trip it. The platform runs it on the
    /// guest just before it pauses the VM. Prints `{"held":true,"until_resume":true}`, or
    /// `held:false` when no systemd watchdog is armed; fails on a daemon from before it.
    #[command(hide = true)]
    WatchdogHold,
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
    /// Delete the history of chats unchanged for longer than `agents.chats.deleteHistoryAfterDays`
    /// (or --older-than-days): closed or archived, not pinned, nothing using them. --dry-run
    /// previews them; --export copies each one first.
    HistoryDelete(HistoryDeleteArgs),
    /// Move old cold-archived chats to cloud history (`agents.chats.cloudOffload`), keeping a stub
    /// that fetches them back on open. --dry-run lists them.
    HistoryOffload(HistoryOffloadArgs),
    /// Run one lifecycle pass now (`agents.chats.lifecycle`): done chats (closed, or idle past
    /// `agents.chats.lifecycleIdleHours`) archived, cold, and offloaded when cloud history is set
    /// up. --dry-run lists them; prints totals and skips by reason.
    Lifecycle(LifecycleArgs),
    /// Copy Claude's and Codex's transcripts to cloud history, read-only (setting
    /// `agents.chats.transcriptOffload`, off by default).
    TranscriptOffload(TranscriptOffloadArgs),
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
pub struct TranscriptOffloadArgs {
    /// List the transcripts and bytes that would be copied and removed locally; upload nothing,
    /// change nothing. Runs here, with no daemon and no cloud needed.
    #[arg(long, conflicts_with = "restore_all")]
    pub dry_run: bool,
    /// Transcripts unchanged for longer than this many days, instead of the setting.
    #[arg(long)]
    pub older_than_days: Option<u32>,
    /// Bring back every transcript a pass removed (undo).
    #[arg(long)]
    pub restore_all: bool,
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

#[derive(Args, Clone, Debug)]
pub struct HistoryDeleteArgs {
    /// Only list the chats a pass would delete, with their size; delete nothing.
    #[arg(long)]
    pub dry_run: bool,
    /// Chats unchanged for longer than this many days, instead of the setting.
    #[arg(long)]
    pub older_than_days: Option<u32>,
    /// Copy each chat's folder to `<folder>/<chat id>/` before it is deleted; a chat whose copy
    /// fails is kept.
    #[arg(long)]
    pub export: Option<PathBuf>,
    /// List Recently deleted: the deleted chats that can still be restored, and when each is
    /// purged.
    #[arg(long, conflicts_with_all = ["dry_run", "older_than_days", "export", "restore"])]
    pub deleted: bool,
    /// Restore a deleted chat (by id or name) before it is purged: back in the lists as it was.
    #[arg(long, value_name = "CHAT", conflicts_with_all = ["dry_run", "older_than_days", "export"])]
    pub restore: Option<String>,
}

#[derive(Args, Clone, Debug)]
pub struct LifecycleArgs {
    /// Only list the chats a pass would take, and why the rest stay.
    #[arg(long)]
    pub dry_run: bool,
}

#[derive(Args, Clone, Debug)]
pub struct HistoryOffloadArgs {
    /// Only list the chats a pass would offload.
    #[arg(long)]
    pub dry_run: bool,
    /// Chats unchanged for longer than this many days, instead of the setting (default 14).
    #[arg(long)]
    pub older_than_days: Option<u32>,
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

/// Why `session stop` closes the session (`close_why.rs`): recorded, never a condition.
#[derive(Args, Clone, Debug, Default, PartialEq, Eq)]
pub struct CloseArgs {
    /// How the session's work ended: `done` or `dropped`. Left out on a lane with work (a
    /// `lane.reportsTo` or `goal` tag), the close is recorded `unfinished`.
    #[arg(long, value_parser = ["done", "dropped"])]
    pub outcome: Option<String>,
    /// Why it is closed, in a few words; kept with the close.
    #[arg(long, value_name = "TEXT")]
    pub reason: Option<String>,
}

/// Map the grouped spellings onto the flat handlers.
pub fn flatten(c: Command) -> Command {
    match c {
        Command::Session(sc) => match sc {
            SessionCmd::Info { session, fields } => Command::Info { session, fields },
            SessionCmd::Cancel { session } => Command::Cancel { session },
            SessionCmd::Stop { session, purge, now, mesh, condition, close } if !mesh.mesh => {
                Command::Kill { session, purge, now, condition, close }
            }
            SessionCmd::Undelete { session } => Command::Undelete { session },
            SessionCmd::Deleted => Command::Deleted,
            SessionCmd::Restart { session } => Command::RestartAgent { session },
            SessionCmd::Route { session, facts, show_facts } => {
                Command::RouteDeath { session, facts, show_facts }
            }
            SessionCmd::Pause { session } => Command::PauseAgent { session },
            SessionCmd::Wake { session } => Command::WakeAgent { session },
            SessionCmd::PlaceSet(args) => Command::PlaceSession(args),
            SessionCmd::Hold { session, fleet, allow, set_allow, reason, status, hold_for } => {
                Command::SessionHold {
                    session,
                    held: true,
                    fleet,
                    allow,
                    set_allow,
                    reason,
                    status,
                    hold_for,
                }
            }
            SessionCmd::Release { session, fleet } => Command::SessionHold {
                session,
                held: false,
                fleet,
                allow: Vec::new(),
                set_allow: Some(Vec::new()),
                reason: None,
                status: false,
                hold_for: None,
            },
            SessionCmd::Icon { session, icon } => Command::Icon { session, icon },
            SessionCmd::Rename { session, new_name, handle, icon } => {
                Command::Rename { session, new_name, handle, icon }
            }
            SessionCmd::Detach { session } => Command::DetachParent { session },
            SessionCmd::Resume { session, open, mesh } if !mesh.mesh => {
                Command::ResumeQueue { session, open }
            }
            SessionCmd::Inbox { session, opts } if opts.digest || opts.dry_run => {
                Command::InboxDigest { session, dry_run: opts.dry_run || !opts.digest }
            }
            control @ (SessionCmd::Start(_)
            | SessionCmd::Receipt { .. }
            | SessionCmd::Stop { .. }
            | SessionCmd::Resume { .. }) => Command::Session(control),
            SessionCmd::Fork { session, name, cwd, force_admit, harness, model } => {
                Command::Fork { session, name, cwd, force_admit, harness, model }
            }
            SessionCmd::Set { session, assignment, team_address } => Command::Set {
                session,
                assignment: assignment
                    .or_else(|| team_address.map(|address| format!("team-address={address}")))
                    .unwrap_or_default(),
            },
            SessionCmd::Allow { session, option, standing_grant } => {
                Command::Allow { session, option, standing_grant }
            }
            SessionCmd::Deny { session } => Command::Deny { session },
            SessionCmd::Answer { session, answer } => Command::Answer { session, answer },
            SessionCmd::Place { session, on, reason } => Command::Place { session, on, reason },
            SessionCmd::Export { session, dest } => Command::Export { session, dest },
            SessionCmd::Import { path, name } => Command::Import { path, name },
            SessionCmd::Transfer { session, to, cwd, name, interrupt, after_turn } => {
                Command::Transfer { session, to, cwd, name, interrupt, after_turn }
            }
            SessionCmd::Move(args) => Command::MoveSessions(args),
            SessionCmd::Rebalance(args) => Command::Rebalance(args),
            SessionCmd::Tail { session, last, follow, since } => {
                Command::Tail { session, last, follow, since }
            }
            SessionCmd::Tag { session, assignments, remove, ttl } => {
                Command::TagCmd { session, assignments, remove, ttl }
            }
            // The tags `hub/auto_settle.rs` reads: archived with a reason, and the override.
            SessionCmd::Settle { session } => Command::TagCmd {
                session,
                assignments: vec![
                    format!("archived={}", crate::store::now_ms()),
                    format!(
                        "{}={}",
                        crate::hub::auto_settle::SETTLED_TAG,
                        crate::hub::auto_settle::Reason::Manual.as_str()
                    ),
                ],
                remove: vec!["unsettled".into()],
                ttl: None,
            },
            SessionCmd::Unsettle { session } => Command::UnsettleCmd { session },
            SessionCmd::AutoSettle { session, mode } => match mode {
                AutoSettleMode::Never => Command::TagCmd {
                    session,
                    assignments: vec!["autoSettle=never".into()],
                    remove: vec![],
                    ttl: None,
                },
                AutoSettleMode::Follow => Command::TagCmd {
                    session,
                    assignments: vec![],
                    remove: vec!["autoSettle".into()],
                    ttl: None,
                },
            },
            SessionCmd::Limits { session, max, clear } => {
                Command::LimitsCmd { session, max, clear }
            }
            SessionCmd::TurnCap { session, minutes, off, clear } => {
                Command::TurnCapCmd { session, minutes, off, clear }
            }
            SessionCmd::Inbox { session, opts } => Command::SessionInboxCmd(SessionInboxTarget {
                session,
                search: opts.search,
                before: opts.before,
                subscribe: opts.subscribe,
                unsubscribe: opts.unsubscribe,
                subscriptions: opts.subscriptions,
                thread: opts.thread,
                unread: opts.mark_read,
            }),
            SessionCmd::Rules { session, rules, clear } => {
                Command::RulesCmd { session, rules, clear }
            }
            SessionCmd::History { session, limit } => Command::History { session, limit },
            SessionCmd::Search(args) => Command::SessionSearch(args),
            SessionCmd::Queue(q) => Command::QueueCmd(q),
        },
        Command::Daemon(dc) => match dc {
            DaemonCmd::Run {
                listen,
                token,
                insecure_network_listen,
                memory,
                log,
                ready_fd,
                person_key_fd,
                allow_dev_origin,
                dev,
                take_over,
            } => Command::DaemonRun {
                listen,
                token,
                insecure_network_listen,
                memory,
                log,
                ready_fd,
                person_key_fd,
                allow_dev_origin,
                dev,
                take_over,
            },
            DaemonCmd::Status { show_token } => Command::Status { show_token },
            DaemonCmd::Start { person_key_fd, show_token } => {
                Command::DaemonStart { person_key_fd, show_token }
            }
            DaemonCmd::Enroll { person_key_fd } => Command::DaemonEnroll { person_key_fd },
            DaemonCmd::Shutdown { keep_agents, end_agents, restart } => {
                Command::Shutdown { keep_agents, end_agents, restart }
            }
            DaemonCmd::Restart => Command::DaemonRestart,
            DaemonCmd::Stats { by, since, top } => Command::DaemonStats { by, since, top },
            DaemonCmd::Felt => Command::DaemonFelt,
            DaemonCmd::WatchdogHold => Command::DaemonWatchdogHold,
            DaemonCmd::Placement { message } => Command::DaemonPlacement { message },
            DaemonCmd::Prune { apply } => Command::DaemonPrune { apply },
            DaemonCmd::Service { action } => Command::DaemonService { action },
            DaemonCmd::Config { show_token, set } => Command::Config { show_token, set },
            DaemonCmd::Harnesses => Command::Harnesses,
            DaemonCmd::Reload => Command::Reload,
            DaemonCmd::Retention(args) => Command::Retention(args),
            DaemonCmd::HistoryDelete(args) => Command::HistoryDelete(args),
            DaemonCmd::HistoryOffload(args) => Command::HistoryOffload(args),
            DaemonCmd::Lifecycle(args) => Command::Lifecycle(args),
            DaemonCmd::TranscriptOffload(args) => Command::TranscriptOffload(args),
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
#[path = "command_help_contract_tests.rs"]
mod help_contract_tests;

#[cfg(test)]
#[path = "intent_tests.rs"]
mod intent_tests;

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

#[cfg(test)]
mod deadline_defaults_tests {
    use super::{Cli, Command};
    use clap::Parser;

    #[test]
    fn send_waits_for_a_live_peer_by_default() {
        let cli = Cli::try_parse_from(["acpmux", "send", "session", "slow reply"]).unwrap();
        match cli.command {
            Some(Command::Send { stall, .. }) => assert_eq!(stall, 0),
            _ => panic!("expected send command"),
        }
    }

    #[test]
    fn explicit_stall_remains_a_caller_choice() {
        let cli = Cli::try_parse_from(["acpmux", "send", "session", "--stall", "7"]).unwrap();
        match cli.command {
            Some(Command::Send { stall, .. }) => assert_eq!(stall, 7),
            _ => panic!("expected send command"),
        }
    }

    /// `acpmux send --gather` (`hub/cold_wake.rs`): a named sender's message or notice that waits
    /// for the chat's batch, and so never waits for its reply.
    #[test]
    fn a_gather_send_parses_and_never_waits_for_a_reply() {
        let parse = |argv: &[&str]| Cli::try_parse_from(argv);
        assert!(parse(&["acpmux", "send", "c", "hi", "--gather", "--from", "forum"]).is_ok());
        let notice = [
            "acpmux",
            "send",
            "c",
            "--notice",
            "--severity",
            "info",
            "--title",
            "T",
            "--sender",
            "slack",
            "--gather",
        ];
        assert!(parse(&notice).is_ok());
        for clash in ["--wait", "--quiet"] {
            assert!(parse(&["acpmux", "send", "c", "hi", "--gather", clash]).is_err(), "{clash}");
        }
    }
}

/// `acpmux exec-router ...`.
#[derive(Debug, clap::Subcommand)]
pub enum ExecCmd {
    /// Each routing decision, newest last: where it ran (fork or here), what sent it (hook,
    /// shim), the program, wall time, exit, bytes back, and the cause when it ran here.
    Trace {
        /// How many of the newest decisions.
        #[arg(long, default_value_t = 20)]
        last: usize,
    },
    /// The identical-result rule (`placement/exec_conformance.rs`): run a fixed corpus of
    /// commands (a tiny cargo build and test, file writes, a failing exit, stdout and stderr
    /// order, creates, deletes, renames and a symlink, ...) in fresh copies of a fixture
    /// checkout, once with CMUX_EXEC_ROUTE=local and once routed, and compare exit code, output
    /// and the resulting file tree. One row per case, then `identical N/M`; exits 1 unless every
    /// case was routed and none differed beyond its documented divergence. Run it in a Cloud
    /// machine session with run VMs on: elsewhere the routed side runs here and proves nothing.
    Conformance {
        /// Only these cases (repeatable); default every case.
        #[arg(long = "case", value_name = "NAME")]
        cases: Vec<String>,
        /// Where the work copies go (default `$ACPMUX_HOME/exec-conformance/run-*`, removed
        /// after a passing run). Must be on the disk a fork copies.
        #[arg(long, value_name = "DIR")]
        dir: Option<std::path::PathBuf>,
        /// Keep the work copies after a passing run too.
        #[arg(long)]
        keep: bool,
    },
}
