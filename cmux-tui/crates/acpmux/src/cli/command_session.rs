//! The `acpmux session` argument grammar (`SessionCmd`) and the send, inbox and listen flags
//! beside it, split from `command.rs`.

use clap::{Args, Subcommand};
use std::path::PathBuf;

use crate::cli::command::{CloseArgs, MoveSessionsArgs, PlaceSessionArgs, RebalanceArgs, StopIf};

/// `session auto-settle`'s choice: the settings decide, or this chat never settles on its own.
#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub enum AutoSettleMode {
    Follow,
    Never,
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
    /// Stop the agent process. The session stays resumable. The stop is recorded with who asked,
    /// `--reason` and `--outcome` (`ls --closed --json` rows' `close`); a lane with work stopped
    /// with no `--outcome` is recorded `unfinished`.
    #[command(alias = "kill", alias = "close")]
    Stop {
        session: String,
        #[command(flatten)]
        mesh: crate::cli::mesh_control::RouteArgs,
        /// Also delete the chat and its log. It is kept 7 days first: `session deleted` lists
        /// it, `session undelete` brings it back with its whole log. A daemon older than that
        /// deletes it at once, and the command says so.
        #[arg(long)]
        purge: bool,
        /// With `--purge`: delete now, with no grace to restore it.
        #[arg(long, requires = "purge")]
        now: bool,
        #[command(flatten)]
        condition: StopIf,
        #[command(flatten)]
        close: CloseArgs,
    },
    /// Bring back a chat deleted with `session stop --purge` inside its 7 days, closed, with its
    /// whole log. SESSION is its id or its name; when a chat took the name meanwhile, it comes
    /// back as NAME-2.
    Undelete { session: String },
    /// The deleted chats that may still be brought back, and until when.
    Deleted,
    /// Pause an idle session: its agent process and MCP servers exit now, as after 2 idle
    /// minutes, and the chat keeps its transcript and conversation. Its next prompt, opening it,
    /// or `session wake` resumes the same conversation. Refused (exit 6) while it is busy.
    Pause { session: String },
    /// Resume a paused session now: its agent starts on the same conversation, and the time it
    /// took is printed. A prompt resumes it too, without this.
    Wake { session: String },
    /// Hold a session: it takes no turn until the person asks for it. Every other agent's
    /// message, tool notice or background task's end waits in its inbox; its idle agent is
    /// paused. Its person's own prompt, opening it in the app, or `session release` lifts it.
    /// With `--fleet`: hold every session on this machine but the allowlist's names (a trailing
    /// `*` matches a prefix, `*TERM*` any name containing TERM in any case), and refuse new
    /// sessions outside them, for 12 hours unless `--for` says otherwise. `--allow` adds names
    /// to the allowlist of a hold that is on and keeps the rest (with no hold on it changes
    /// nothing); `--set-allow` replaces it. Prints the allowlist before and after.
    Hold {
        /// The session (not with `--fleet`).
        session: Option<String>,
        /// Hold this machine's whole fleet of sessions.
        #[arg(long)]
        fleet: bool,
        /// With `--fleet`: names added to the allowlist (it keeps the ones already there),
        /// comma-separated: `NAME`, `PREFIX*` or `*TERM*`.
        #[arg(long, value_delimiter = ',')]
        allow: Vec<String>,
        /// With `--fleet`: replace the whole allowlist with these names (then `--allow` adds to
        /// it); `--set-allow ''` empties it.
        #[arg(long, value_delimiter = ',', num_args = 0..=1)]
        set_allow: Option<Vec<String>>,
        /// With `--fleet`: why, shown in each refusal.
        #[arg(long)]
        reason: Option<String>,
        /// With `--fleet`: print the fleet hold, change nothing.
        #[arg(long)]
        status: bool,
        /// With `--fleet`: how long it holds (`30m`, `4h`, `2d`; `never` keeps it until
        /// released). Default 12h.
        #[arg(long = "for", value_name = "DURATION")]
        hold_for: Option<String>,
    },
    /// Release a held session (`session hold`): it runs its next prompt as usual. With
    /// `--fleet`: lift the fleet hold.
    Release {
        session: Option<String>,
        #[arg(long)]
        fleet: bool,
    },
    /// Restart the agent process in the same conversation: now when the
    /// session is between turns, else when its turn ends (never cancelled).
    /// It then runs the installed version and gets a new caller token (after
    /// a daemon restart left it the earlier daemon's).
    Restart { session: String },
    /// Decide what happens next to a session that died while it owned work: restart it in
    /// place, move it, start its host, start it again on a healthy host, start a successor,
    /// wait, or hand its work off. Reads FACTS (a JSON file, `-` for stdin: its host, how it
    /// died, what was tried, which hosts admit one more session) and prints one JSON step,
    /// `{"step": "restart"|"move"|"successor"|...}`. Runs nothing; the caller runs the step
    /// (`session restart`, `session move`) and asks again on its next pass. Name the session
    /// (`HOST/NAME`) and this machine's hub fills what it knows first: whether its host is down
    /// and since when, which peers answer, its row and how much of its chat the copy here keeps;
    /// FACTS, when given, lie over those field by field. `--show-facts` prints both.
    Route {
        /// The dead session, `HOST/NAME`.
        session: Option<String>,
        #[arg(long, value_name = "FILE")]
        facts: Option<PathBuf>,
        /// Print `{facts, step}`: the facts the step was decided on, then the step.
        #[arg(long)]
        show_facts: bool,
    },
    /// Rename a session.
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
    /// Set the icon every surface draws for a session (as `acpmux icon`).
    Icon { session: String, icon: Option<String> },
    /// Detach a session from the session that started it: its turns stop showing in that
    /// session's chat, and its `lane.reportsTo` tag goes. The session keeps running.
    Detach { session: String },
    /// Run the queued prompts a failed turn held. An agent or a script may resume a
    /// queue; only answering a permission or a question needs the cmux app. On a machine a
    /// person works at, a stopped chat first moves to a fleet machine, as `session move --machine
    /// auto` does; when none takes it, it resumes here and says why. A queue a daemon start
    /// holds for a person (its folder is guarded: `hub/protected_hold.rs`) is named, with how to
    /// release it; `--open` releases it as opening the chat in cmux does.
    Resume {
        session: String,
        /// Open the chat as the cmux app does when a person clicks it, then resume: what a
        /// daemon start held for a person (a guarded folder) runs now.
        #[arg(long)]
        open: bool,
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
        /// Continue on another harness (a family or profile): the fork's agent gets the chat's
        /// conversation with its first prompt.
        #[arg(long)]
        harness: Option<String>,
        /// The model the fork runs, on --harness or the chat's own harness (MODEL or
        /// HARNESS/MODEL). A model the harness does not list fails the fork.
        #[arg(long, short)]
        model: Option<String>,
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
    /// only from the cmux app (approve it on the Mac app), or signed with this
    /// machine's standing grant (--standing-grant); a deny option works from here.
    Allow {
        session: String,
        option: Option<String>,
        /// Sign the one-time allow with the standing grant
        /// (`acpmux machine approvals grant` records it).
        #[arg(long)]
        standing_grant: bool,
    },
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
    /// Move a chat between Local (this Mac), Cloud (stays in cmux Cloud) and AutoCloud (here
    /// while the Mac is up, in the Cloud while it sleeps), through Auto mode's fenced handoff. The
    /// person may make any move; a chat's own agent may move it off the Mac only while the
    /// AutoCloud setting is on, and back to local, also from the Cloud machine it runs on (else
    /// the answer says needs_person and the command). `cmux chat move SESSION --on PLACE` runs
    /// this.
    Place {
        session: String,
        /// local, cloud or auto (autocloud).
        #[arg(long)]
        on: String,
        /// Why, for the log.
        #[arg(long)]
        reason: Option<String>,
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
    Move(MoveSessionsArgs),
    /// Place an existing chat as the place menu does: `--mode auto`, `--mode cloud` or `--mode machine --machine NAME`. A chat moves only between turns (mid-turn it
    /// moves after the turn); a move that leaves something behind lists it and needs `--yes`;
    /// each move writes one line in the chat. `--undo` moves back; `--status` reads the pin.
    #[command(name = "place-set")]
    PlaceSet(PlaceSessionArgs),
    /// Move this machine's excess chats off when it holds more live chats than its lanes.max_lanes:
    /// only chats between turns with no work running below them, at most a few a pass, to the
    /// machines placement gives room. Each move leaves a receipt whose undo moves it back. Off
    /// unless the fleet registry's lane_overflow.rebalance.enabled is true (then it only plans).
    Rebalance(RebalanceArgs),
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
        #[arg(long, conflicts_with = "after_turn")]
        interrupt: bool,
        /// Let a running turn end on its own, then move.
        #[arg(long)]
        after_turn: bool,
    },
    /// Print the last raw events as JSON lines; -f keeps following.
    Tail {
        session: String,
        #[arg(long, short = 'n', visible_alias = "tail", default_value_t = 50)]
        last: u64,
        #[arg(long, short)]
        follow: bool,
        /// Start after a cursor (`<sessionId>:<seq>` or a seq), or use `seen` for the reader's cutover.
        /// A chat the reader has never focused has no recap.
        #[arg(long)]
        since: Option<String>,
    },
    /// Settle a chat now: archived, off every list, on the Settled shelf (`hub/auto_settle.rs`).
    Settle { session: String },
    /// Bring a settled (or archived) chat back to the lists.
    Unsettle { session: String },
    /// Whether the auto-settle settings (`agents.autoSettle.*`) apply to this chat.
    AutoSettle {
        session: String,
        #[arg(value_enum)]
        mode: AutoSettleMode,
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
    /// Find the session's messages that hold every word of TEXT, newest first.
    Search(crate::cli::session_search::SearchArgs),
    /// The prompts waiting for the running turn: list, remove PROMPT_ID..., clear --from-agents.
    #[command(subcommand)]
    Queue(crate::cli::session_queue::QueueCmd),
}

// The inbox's flags (`hub/inbox.rs`) are `Args` of their own, flattened: each builds in its own
// frame. Inline, the derived builder's one frame for every command's flags overflowed libtest's
// 2 MiB thread in a debug build.

/// `acpmux send --notice`: a tool's or reconciler's notice (`_meta.acpmux.notice`,
/// `prompt_provenance::notice_of`). The chat draws it as a notice row (severity, sender, title,
/// links); its agent, and a daemon or page that knows no notice, read the rendered text
/// `[notice from SENDER on HOST · FIRE] TITLE`, the body, then `Links: …`.
#[derive(clap::Args, Debug, Default, Clone)]
pub struct SendNotice {
    /// Send it as a tool's notice, with --severity and --title (the prompt text is its body).
    /// It is a named sender's message, never the person's.
    #[arg(long, requires_all = ["severity", "title"])]
    pub notice: bool,
    /// How loud the notice is: info, warn or fire.
    #[arg(long, value_name = "SEVERITY", value_parser = ["info", "warn", "fire"], requires = "notice")]
    pub severity: Option<String>,
    /// The notice's one-line title (at most 200 characters).
    #[arg(long, value_name = "TITLE", requires = "notice")]
    pub title: Option<String>,
    /// Who sends the notice, a tool or role (default: --from, ACPMUX_FROM, else this session's
    /// name).
    #[arg(long, value_name = "NAME", requires = "notice")]
    pub sender: Option<String>,
    /// The machine it comes from (default: this one).
    #[arg(long, value_name = "HOST", requires = "notice")]
    pub host: Option<String>,
    /// A link the notice carries, `URL` or `URL=LABEL`, https only (repeatable, at most 16).
    #[arg(long = "link", value_name = "URL[=LABEL]", requires = "notice")]
    pub links: Vec<String>,
}

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

/// `acpmux send --relay NAME --relayed-from MACHINE[/SESSION]`: a relay's word on where the
/// message it carries came from (`_meta.acpmux.fromRelay`, `prompt_provenance::FROM_RELAY`). The
/// daemon takes it only from a send run outside any acpmux session on its own machine (the
/// lane-gh broker's); an agent's send drops it, and its sender reads as self-declared.
#[derive(Args, Default)]
pub struct SendRelay {
    /// The relay carrying the message, as it names itself (`lane-gh`).
    #[arg(long, value_name = "NAME", requires = "relayed_from")]
    pub relay: Option<String>,
    /// The machine the relay took the message from, and its session there.
    #[arg(long, value_name = "MACHINE[/SESSION]", requires = "relay")]
    pub relayed_from: Option<String>,
    /// That session's harness family (`claude`, `codex`, `gemini`, ...), in the machine's word.
    #[arg(long, value_name = "FAMILY", requires = "relay")]
    pub relayed_harness: Option<String>,
}

/// `acpmux session inbox NAME`'s flags.
#[derive(Args, Default)]
pub struct SessionInboxOpts {
    /// Search the full text, sender and thread of surge-held messages.
    #[arg(long, conflicts_with_all = ["thread", "digest", "dry_run"])]
    pub search: Option<String>,
    /// Continue a held-inbox search before this sequence number.
    #[arg(long, requires = "search")]
    pub before: Option<u64>,
    /// Bind a surge thread to this recipient session for durable triage ownership.
    #[arg(long, value_name = "THREAD", conflicts_with_all = ["search", "unsubscribe", "subscriptions", "thread", "digest", "dry_run"])]
    pub subscribe: Option<String>,
    /// Remove this recipient session's durable surge thread binding.
    #[arg(long, value_name = "THREAD", conflicts_with_all = ["search", "subscribe", "subscriptions", "thread", "digest", "dry_run"])]
    pub unsubscribe: Option<String>,
    /// List this recipient session's durable surge thread bindings.
    #[arg(long, conflicts_with_all = ["search", "subscribe", "unsubscribe", "thread", "digest", "dry_run"])]
    pub subscriptions: bool,
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
    pub search: Option<String>,
    #[arg(long, requires = "search")]
    pub before: Option<u64>,
    #[arg(long, value_name = "THREAD", conflicts_with_all = ["search", "unsubscribe", "subscriptions", "thread"])]
    pub subscribe: Option<String>,
    #[arg(long, value_name = "THREAD", conflicts_with_all = ["search", "subscribe", "subscriptions", "thread"])]
    pub unsubscribe: Option<String>,
    #[arg(long, conflicts_with_all = ["search", "subscribe", "unsubscribe", "thread"])]
    pub subscriptions: bool,
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
pub enum ListenCmd {
    /// Open a listen on a teammate's agent address.
    Open {
        /// The address, @member/agent.
        address: String,
        /// How long it stays open, in seconds (60 to 604800; the hub's default without it).
        #[arg(long, value_name = "SECONDS")]
        ttl: Option<u64>,
    },
    /// List your listens and others' on your addresses.
    Ls,
    /// Close one of your listens by id.
    Close { id: String },
    /// Read the messages an address you listen on received.
    Read {
        /// The address, @member/agent.
        address: String,
        /// Continue from the previous JSON response's `next` cursor.
        #[arg(long)]
        before: Option<u64>,
    },
}
