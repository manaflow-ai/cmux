//! The turn session's system prompt and the turn's prompt (sections 7 and 7.2).
//! Everything here is constant: the prompt and the tool list head every
//! cached prefix, so they hold no dates, no state and no per-turn text.

use serde_json::{Value, json};

/// The agent's name in the prompts (section 7.2: rename the agent).
pub const AGENT: &str = "Chief";

/// MASTER from section 7.2 with the agent renamed, and one deviation
/// (README): its line on messages sent mid-run says what the host does
/// (decision 2026-10-04) instead of "reach you between tool calls".
pub const MASTER: &str = "You are Chief, an AI agent that works for one user in a single chat that
never ends. Do the user's tasks yourself, with your tools, following
the user's instructions at the end of this prompt: they say who the
user is, how their files are organized and how they want work done.
Use subagents only when the user asks for them.

You keep no memory between turns. Each turn starts with the view below,
followed by the user's new message. Summaries keep little of tool
output, so say in your reply what you learned that will matter later.
A message the user sends while you work interrupts you at once, even
mid-thought; a tool call already running finishes first, then you go on
with the message.

Subagents and computer tasks run in the background. Each one's report
reaches you as a message starting \"[id] \": between your tool calls
while you work, or as a new turn once yours has ended. So never wait
for one (no sleep, no polling): go on, or end your turn and tell the
user what is running.";

/// VIEW_DOC, verbatim from section 7.2 with the agent renamed.
pub const VIEW_DOC: &str =
    "The view: the whole chat between Chief and the user, oldest first, inside
<chat> tags, as one-line summaries. Each line is

  id+n|text   the n messages from id on, summarized (newlines shown as spaces)

A summary tags each item with its kind: user (the user's words), talk
(Chief's replies), tool (Chief's tool calls), echo (their results), note
(memories from before this chat), or work (the report of a subagent or
a computer task, which the log holds as a user message starting
\"[id] \"). A short message is its own line, word for word. Recent lines
cover one message each; the older the messages, the more a line covers.
A message not summarized yet shows as \"(not summarized yet: zoom it)\".
No message appears in full, not even the last ones.

Navigating: zoom(id, n) opens line id+n into the two lines of n/2
messages it was made from; zoom(id, 1) gives message id in full. Zoom
whenever a summary only mentions something you need, such as what your
last reply said, a decision, a past attempt or where a file is, before
you act, guess or ask. date(id) gives the date and time of message id.";

/// The third part of the system prompt, where section 7.2 puts the user's own
/// instructions file: how this Chief works inside cmux. It names no user and
/// holds nothing that changes per turn.
pub const CMUX_INSTRUCTIONS: &str = "# Instructions

You run inside cmux, a terminal for coding agents; the user talks to you in
cmux Home, and your final reply of each turn is posted there.

- Workspaces, panes, terminals and browsers: use the `cmux` MCP tools when
  you have them, else the `cmux` CLI from your shell (`cmux --help`). It
  drives the user's cmux app; it never moves the user's focus unless you ask
  for it. Never close or change workspaces the user did not ask about.
- Subagents: the tool `spawn(tasks)` starts one subagent per task, in
  parallel, in the background, each in its own cmux workspace where the user
  can watch and join its chat; it answers their ids at once. A subagent sees
  your view and its task, so say in the task what it must do and report.
  When all of one spawn's subagents finish, their reports reach you as ONE
  message, \"[id] report\" each. `tell(id, message)` sends a running
  subagent more instructions. Never wait or poll for them.
- The tools `zoom` and `date` (MCP server `optchat`) read your memory.";

/// The system prompt (the session's CLAUDE.md): MASTER, VIEW_DOC, the cmux
/// section, then the user's own instructions file (section 7.2), read once
/// per host start so every turn's prompt stays byte-identical.
pub fn claude_md(user: Option<&str>) -> String {
    match user.map(str::trim).filter(|u| !u.is_empty()) {
        Some(user) => format!("{MASTER}\n\n{VIEW_DOC}\n\n{CMUX_INSTRUCTIONS}\n\n{user}\n"),
        None => format!("{MASTER}\n\n{VIEW_DOC}\n\n{CMUX_INSTRUCTIONS}\n"),
    }
}

/// How a turn reaches its memory tools: Claude Code harnesses get the
/// `optchat` MCP server (the session directory's `.mcp.json`); any other
/// harness gets no MCP server through acpmux and runs the `chief` launcher
/// (its absolute path) from its shell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Tools {
    Mcp,
    Cli(String),
}

/// The system prompt for `tools`: MASTER, VIEW_DOC, the cmux section (its
/// tool lines for `tools`), then the user's instructions file.
pub fn system_text(user: Option<&str>, tools: &Tools) -> String {
    let cmux = match tools {
        Tools::Mcp => CMUX_INSTRUCTIONS.to_owned(),
        Tools::Cli(chief) => cli_instructions(chief),
    };
    match user.map(str::trim).filter(|u| !u.is_empty()) {
        Some(user) => format!("{MASTER}\n\n{VIEW_DOC}\n\n{cmux}\n\n{user}\n"),
        None => format!("{MASTER}\n\n{VIEW_DOC}\n\n{cmux}\n"),
    }
}

/// The cmux section for a harness without the `optchat` MCP server: the
/// launcher by its absolute path (it is not on that harness's PATH), and the
/// memory tools as its `zoom` and `date` commands.
fn cli_instructions(chief: &str) -> String {
    format!(
        "# Instructions

You run inside cmux, a terminal for coding agents; the user talks to you in
cmux Home, and your final reply of each turn is posted there.

- Workspaces, panes, terminals and browsers: use the `cmux` CLI from your
  shell (`cmux --help`). It drives the user's cmux app; it never moves the
  user's focus unless you ask for it. Never close or change workspaces the
  user did not ask about.
- Subagents: `{chief} spawn \"task\" [\"task\" ...]` starts one subagent per
  task, in parallel, in the background, each in its own cmux workspace where
  the user can watch and join its chat; it prints their ids at once. A
  subagent sees your view and its task, so say in the task what it must do
  and report. When all of one spawn's subagents finish, their reports reach
  you as ONE message, \"[id] report\" each. `{chief} tell ID \"message\"`
  sends a running subagent more instructions. Never wait or poll for them.
- Your memory: `zoom(id, n)` is `{chief} zoom ID N` and `date(id)` is
  `{chief} date ID`, run from your shell."
    )
}

/// The subagent system prompt of section 9, verbatim with the agent renamed.
pub const SUBAGENT: &str = "You are a subagent of Chief, an AI agent that works for one user in a
single chat that never ends. Chief gave you a task. Do it yourself, with
your tools, following the user's instructions at the end of this
prompt: they say who the user is, how their files are organized and how
they want work done.

Your first message holds the view below, then your task. The view shows
you what Chief knows: what the user wants, decided and taught. Use it as
context only, and do what your task says, not what the user's last
message says, since Chief may have given you just part of the work. Your
final reply is your report to Chief. Chief may send you more messages, even
while you work.";

/// The cmux section of a subagent's system prompt: its memory tools (no
/// spawn: section 9), and that the user may join its chat.
fn subagent_instructions(tools: &Tools) -> String {
    let memory = match tools {
        Tools::Mcp => {
            "The tools `zoom` and `date` (MCP server `optchat`) read Chief's memory.".to_owned()
        }
        Tools::Cli(chief) => format!(
            "Chief's memory: `zoom(id, n)` is `{chief} zoom ID N` and `date(id)` is\n  `{chief} date ID`, run from your shell."
        ),
    };
    format!(
        "# Instructions

You run inside cmux, a terminal for coding agents, in a workspace of your
own; the user can watch your chat there and write to you. A message from
the user is the user's word; still end each turn with your report.

- {memory}
- The `cmux` CLI drives the user's cmux app (`cmux --help`). Never close
  or change workspaces the user did not ask about."
    )
}

/// A subagent's system prompt: SUBAGENT, VIEW_DOC, the cmux section, then
/// the user's instructions file (section 9).
pub fn subagent_system_text(user: Option<&str>, tools: &Tools) -> String {
    let cmux = subagent_instructions(tools);
    match user.map(str::trim).filter(|u| !u.is_empty()) {
        Some(user) => format!("{SUBAGENT}\n\n{VIEW_DOC}\n\n{cmux}\n\n{user}\n"),
        None => format!("{SUBAGENT}\n\n{VIEW_DOC}\n\n{cmux}\n"),
    }
}

/// A subagent's first message (section 9): the view at spawn time, one
/// block per cached piece, then its task. No marker of ours: the subagents
/// of one spawn start together, so none could read another's entry, and
/// Claude Code's own breakpoint at the message's end serves the subagent's
/// later requests.
pub fn subagent_blocks(view: &str, task: &str) -> Vec<Value> {
    turn_blocks(view, &[format!("Your task:\n\n{task}")])
}

/// Tool descriptions of section 9's `spawn` and `tell`.
pub const SPAWN_DESCRIPTION: &str = "Start one subagent per task, in parallel, in the background; answers their ids at once. Each sees the view and its task, in a cmux workspace of its own. When all of them finish, their reports reach you as one message, \"[id] report\" each. Never wait or poll for them.";
pub const TELL_DESCRIPTION: &str =
    "Send a message to a running subagent; it reaches it after its current step.";

/// A prompt in the cached layout: the session's system prompt and the user
/// blocks.
#[derive(Clone, Debug, PartialEq)]
pub struct CachedPrompt {
    pub system: String,
    pub blocks: Vec<Value>,
}

/// The cached layout of `context` (a view) between `system` and `tail`
/// (README, Cache layout): `system` plus the context up to its first cache
/// mark (50k) is the session's system prompt; the rest of the context
/// follows as one block per piece, the piece that ends at the last mark
/// (100k, else the last past the first) carrying the one `cache_control`
/// marker when `marker`; then `tail`. Claude Code puts its own breakpoints
/// on the system prompt and the last messages (three of the API's four), so
/// one marker is all a request may add.
pub fn cached_layout(system: &str, context: &str, tail: &str, marker: bool) -> CachedPrompt {
    let text = |t: &str| json!({"type": "text", "text": t});
    let marks = optchat_core::cache_marks(context);
    let Some(&first) = marks.first() else {
        return CachedPrompt {
            system: system.to_owned(),
            blocks: vec![text(context), text(tail)],
        };
    };
    let mut cuts = marks.clone();
    cuts.push(context.len());
    let mut blocks: Vec<Value> = cuts
        .windows(2)
        .map(|w| text(&context[w[0]..w[1]]))
        .collect();
    // The pieces after the first mark: the one ending at the last mark is
    // the second to last block (the last piece runs to the end).
    if marker && marks.len() >= 2 {
        let at = blocks.len() - 2;
        blocks[at]["cache_control"] = json!({"type": "ephemeral"});
    }
    blocks.push(text(tail));
    CachedPrompt {
        system: format!("{system}\n\n{}", &context[..first]),
        blocks,
    }
}

/// The user's instructions file, `$MUX_HOME/optchat/AGENTS.md` (None when
/// missing or empty).
pub fn user_instructions(path: &std::path::Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .filter(|t| !t.trim().is_empty())
}

/// Tool descriptions, verbatim from section 7.1.
pub const ZOOM_DESCRIPTION: &str = "Open the line id+n of the view into the two lines of n/2 under it; n = 1 gives the message whole.";
pub const DATE_DESCRIPTION: &str = "The date and time of message id.";

/// The turn's user message (section 7): the view rendered before the new
/// messages were logged, then the new messages joined by a blank line.
///
/// The view goes as up to four text blocks, cut at its cache marks (section 8:
/// the last line end before 50k, 80k and 100k characters), so a harness that
/// puts a breakpoint on each block lets the next turn read the unchanged
/// start of the view. Deviation: acpmux's Claude Code path forwards text
/// blocks without `cache_control`, and Claude Code places its own breakpoints
/// (never inside the view), so with claude-sr no breakpoint lands on these
/// cuts yet and a turn rewrites the view instead of reading it. Each turn's
/// host.log line (`turn::usage_line`) shows what the first request read.
pub fn turn_blocks(view: &str, texts: &[String]) -> Vec<Value> {
    let mut blocks: Vec<Value> = optchat_core::cache_pieces(view)
        .into_iter()
        .map(|piece| json!({"type": "text", "text": piece}))
        .collect();
    blocks.push(json!({"type": "text", "text": texts.join("\n\n")}));
    blocks
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_md_is_byte_stable_and_names_no_user() {
        assert_eq!(claude_md(None), claude_md(None));
        let text = claude_md(None);
        assert!(!text.contains("OptChat"), "the agent is renamed");
        assert!(text.starts_with("You are Chief, an AI agent"));
        assert!(text.contains("\n\nThe view: the whole chat between Chief and the user"));
        assert!(text.contains("before\nyou act, guess or ask."));
        assert!(text.ends_with("read your memory.\n"));
    }

    /// Audit round 2: the user's own instructions file comes last (section 7.2).
    #[test]
    fn the_users_instructions_come_last() {
        let text = claude_md(Some("I keep worktrees under ~/w.\n"));
        assert!(text.starts_with("You are Chief"));
        assert!(text.ends_with("read your memory.\n\nI keep worktrees under ~/w.\n"));
        assert_eq!(claude_md(Some("  \n")), claude_md(None));
    }

    #[test]
    fn the_turn_prompt_is_two_blocks() {
        let blocks = turn_blocks("<chat>\n</chat>", &["one".into(), "two".into()]);
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0]["text"], "<chat>\n</chat>");
        assert_eq!(blocks[1]["text"], "one\n\ntwo");
    }
}
