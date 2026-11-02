//! The `acpmux new` (and `run`, `exec`) argument grammar, split from `command.rs`.

use clap::Args;
use std::path::PathBuf;

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
    /// Start it with no parent, though this command runs inside a session: it is not that
    /// session's child, and its turns never show in that session's chat. `acpmux session detach`
    /// does the same for a session already started.
    #[arg(long, conflicts_with = "parent")]
    pub no_parent: bool,
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
