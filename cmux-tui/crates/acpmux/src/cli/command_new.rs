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
    /// Compatibility spelling for `--machine local`.
    #[arg(long, conflicts_with = "host")]
    pub stay: bool,
    /// Session name. Generated when omitted. With a launcher flag it is lowercased
    /// and `/` or spaces become `-` (`gui/x` is `gui-x`).
    #[arg(long, short)]
    pub name: Option<String>,
    #[arg(long)]
    pub cwd: Option<PathBuf>,
    /// Permission policy: ask, approve-reads, approve-edits, approve-all, deny-all, or `review`
    /// for a reviewer: reads, searches and read-only shell commands (`git log`/`diff`/`show`,
    /// `grep`, `rg`, `ls`, `cat`, `sed -n`) run unasked, and every write or other command is
    /// denied at once, so it never waits for a person
    /// (`acpmux run -m claude --policy review "review the diff in ~/proj"`).
    #[arg(long)]
    pub policy: Option<String>,
    /// The harness mode to start in (e.g. `auto`). One that does not ask needs the
    /// person in cmux NEXT, a preset the person approved, or this command running
    /// inside a session that is in that mode.
    #[arg(long)]
    pub mode: Option<String>,
    /// HARNESS[/MODEL]: a family or profile name (`claude`, `codex`, `omp`), optionally with a model
    /// (`claude/opus`, `codex/gpt-5.5`, `opencode/zai/glm-5.1`). Omitted: the default harness and its defaults.
    #[arg(long, short, visible_alias = "harness")]
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
    /// Compatibility spelling that sends the first prompt and waits for its reply.
    #[arg(long)]
    pub wait: bool,
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
    /// Report prompt_stalled (exit 1) when nothing happens for this many seconds; 0 disables. The default waits for the live peer.
    #[arg(long, default_value_t = 0)]
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
    /// When a session named --name (in any case) already exists, use it instead of failing;
    /// the first prompt is not sent to it again.
    #[arg(long)]
    pub reuse: bool,
    /// Create the session even when its host refuses new ones (disk under its
    /// floor; the fleet registry's max_lanes only warns). The daemon logs it.
    #[arg(long)]
    pub force_admit: bool,
    /// With --json, print the whole record, with the command, tool and option catalogs that
    /// `--json` leaves out (about 23 of a Claude session's 27 KB). `acpmux --json session info
    /// NAME` prints them too.
    #[arg(long)]
    pub full: bool,
    /// Refuse to start unless the session asks before each change: a policy narrower than
    /// approve-all, no --mode, and a harness the reviewed asking table lists
    /// (`hub/require_asking.rs`). The acpmux MCP server's guest `new` passes it.
    #[arg(long, hide = true)]
    pub require_asking: bool,
    /// The first prompt is SENDER's message (`_meta.acpmux.fromAgent`), never the person's
    /// words, as `acpmux send --from` makes it. The acpmux MCP server's guest `new` passes its
    /// app's name (`acpmux_mcp_guest.rs`).
    #[arg(long, value_name = "SENDER", hide = true)]
    pub from: Option<String>,
}

impl NewArgs {
    /// Normalize legacy spellings before launch preparation, so every later path sees the same
    /// name, target, and wait behavior.
    pub fn apply_compat(&mut self) -> Vec<&'static str> {
        let mut notices = Vec::new();
        // Only a word that reads as a session name: a quoted prompt with spaces stays a prompt.
        if self.name.is_none()
            && self.prompt.len() == 1
            && self.prompt.first().is_some_and(|word| looks_like_session_name(word))
            && self.prompt_file.is_none()
            && self.worktree.is_none()
            && self.report_to.is_none()
            && self.group.is_none()
            && !self.reuse
            && !self.detach
            && !self.quiet
            && !self.ephemeral
            && self.parent.is_none()
        {
            self.name = self.prompt.pop();
            notices
                .push("acpmux new: the lone positional is the session name, equivalent to --name");
        }
        if self.stay {
            self.host = Some("local".to_owned());
            notices.push("acpmux new: --stay is a compatibility spelling for --machine local");
        }
        if self.wait {
            let has_prompt = !self.prompt.join(" ").trim().is_empty() || self.prompt_file.is_some();
            if has_prompt {
                self.detach = false;
                self.quiet = true;
                notices.push("acpmux new: --wait sends the first prompt and waits for its reply");
            } else {
                self.detach = true;
                notices.push(
                    "acpmux new: --wait had no first prompt, so it created the session without a turn",
                );
            }
        }
        notices
    }
}

/// A lone `new` word is a session name only when it could be one: non-empty, no whitespace,
/// not an option-looking `-` word.
fn looks_like_session_name(word: &str) -> bool {
    !word.is_empty() && !word.starts_with('-') && !word.chars().any(char::is_whitespace)
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn a_lone_prompt_with_spaces_stays_the_prompt() {
        let mut args = New::try_parse_from(["new", "fix the bug"]).unwrap().args;
        let notices = args.apply_compat();
        assert_eq!(args.prompt, ["fix the bug"]);
        assert!(args.name.is_none());
        assert!(notices.is_empty());
    }

    #[derive(Parser)]
    struct New {
        #[command(flatten)]
        args: NewArgs,
    }

    #[test]
    fn compatibility_spellings_keep_the_name_and_wait_on_local() {
        let mut args = New::try_parse_from([
            "new",
            "codex-nightly-check",
            "--harness",
            "codex",
            "--stay",
            "--wait",
        ])
        .unwrap()
        .args;
        let notices = args.apply_compat();
        assert_eq!(args.name.as_deref(), Some("codex-nightly-check"));
        assert!(args.prompt.is_empty());
        assert_eq!(args.host.as_deref(), Some("local"));
        assert!(args.detach);
        assert_eq!(notices.len(), 3);
    }

    #[test]
    fn wait_with_an_explicit_name_keeps_the_name_without_a_prompt() {
        let mut args =
            New::try_parse_from(["new", "--name", "codex-nightly-check", "--stay", "--wait"])
                .unwrap()
                .args;
        let notices = args.apply_compat();
        assert_eq!(args.name.as_deref(), Some("codex-nightly-check"));
        assert!(args.prompt.is_empty());
        assert_eq!(args.host.as_deref(), Some("local"));
        assert!(args.detach);
        assert_eq!(notices.len(), 2);
    }

    #[test]
    fn prompt_aliases_keep_their_single_positional_prompt() {
        for mut args in [
            New::try_parse_from(["new", "do the work", "--detach"]).unwrap().args,
            New::try_parse_from(["new", "do the work", "--quiet"]).unwrap().args,
        ] {
            args.apply_compat();
            assert_eq!(args.prompt, ["do the work"]);
            assert!(args.name.is_none());
        }
    }

    #[test]
    fn wait_with_a_prompt_uses_an_explicit_name_to_disambiguate() {
        let mut args =
            New::try_parse_from(["new", "--name", "codex-nightly-check", "--wait", "do the work"])
                .unwrap()
                .args;
        args.apply_compat();
        assert_eq!(args.name.as_deref(), Some("codex-nightly-check"));
        assert_eq!(args.prompt, ["do the work"]);
        assert!(args.quiet);
        assert!(!args.detach);
    }

    #[test]
    fn wait_without_a_prompt_creates_without_opening_the_tui() {
        let mut args = New::try_parse_from(["new", "--wait"]).unwrap().args;
        let notices = args.apply_compat();
        assert!(args.detach);
        assert!(!args.quiet);
        assert_eq!(notices.len(), 1);
    }
}
