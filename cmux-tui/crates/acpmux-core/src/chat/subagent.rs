use std::collections::{HashMap, HashSet};

/// The subagents seen in one session, each mapped to its parent subagent
/// (`None` for the session's own).
#[derive(Debug, Default)]
pub struct SubagentTree {
    pub parents: HashMap<String, Option<String>>,
    /// Children whose sender was not in the replay window yet. Once that sender
    /// appears, they can be restored as genuine grandchildren.
    pub pending: HashMap<String, HashSet<String>>,
    /// Bounded per-child text; projected only on existing lifecycle/progress events.
    pub previews: HashMap<String, ChildPreview>,
    /// The session's own agent session id (its harness thread), once known:
    /// never one of its subagents.
    pub own: Option<String>,
    /// The background subagents still running: they outlive the turn that
    /// started them, so the session works on past it (`hub/work_below.rs`).
    pub background: HashSet<String>,
    /// Every subagent ever marked background, ended ones included: one that ended (a failed
    /// Claude agent) and runs again (SendMessage resumed it, its retry went on) says `running`
    /// without the mark, and is background work again. Its ids are among `parents`' keys and
    /// leave with them (a root learned late), so it holds no more than the tree already does; the
    /// tree goes with its hub session.
    pub was_background: HashSet<String>,
    /// Every subagent that runs now (live updates only), foreground or background, at any
    /// depth, oldest first, each with the label a list names it by (its name, else its task):
    /// the summary's `subagentsRunning` and `subagentNames` (`hub/views.rs`).
    pub running: Vec<(String, Option<String>)>,
    /// Each subagent's name, from the newest event that named it (its spawn, a workflow's launch). An
    /// event that names it not (a progress or state update) is given it, so a client that read the chat's log from a
    /// page after the spawn still names the subagent and not its raw id (Leo, 2026-11-02, on
    /// Session Info rows named "01a18fcd-c1c7-7c…": "but what's going on with these?").
    pub names: HashMap<String, String>,
    /// Codex's native ids for this session. Legacy activity can echo a root id
    /// while a child is running; it is the root, never a subagent. The tree
    /// lives as long as the hub session, and a harness restart or a new Codex
    /// conversation names a new root, so every root learned is kept: replayed
    /// history still names the earlier ones.
    pub root_threads: HashSet<String>,
}

#[derive(Debug, Default)]
pub struct ChildPreview {
    pub text: String,
    pub message_id: Option<String>,
    pub streaming: bool,
    pub tokens: Option<u64>,
    /// The `task` its spawn (or a later progress) gave it (Claude's Agent `description`). A state
    /// or progress update that says none carries it, as `names` carries its name, so a reader
    /// whose page starts after the spawn still names it by its description (Leo, 2026-11-03: a
    /// background agent's end read "Subagent finished: Subagent").
    pub task: Option<String>,
    /// The `agentId` an event of it gave (a Claude agent's task id, the id SendMessage names it
    /// by), carried onto a later event that says none: its completed or cancelled end, so a page
    /// holding only that end still says which agent it was (cmux#33292, cmux#33336).
    pub agent_id: Option<String>,
    /// The current message's whole text, for the `result` its `completed` end carries (the chat's
    /// "Subagent finished" card shows the whole reply; `text` is the tray's capped one-liner). Leo,
    /// 2026-11-09: "this isn't rendering the full message". Bounded by `RESULT_CHARS`, freed at
    /// the child's end, so only live children hold one.
    pub result: String,
    /// `result`'s char count, so a chunk appends in O(chunk), not a recount per token.
    pub result_chars: usize,
    /// The message outgrew `RESULT_CHARS` (or came in capped): its end carries no `result`, and
    /// the client falls back to `lastMessage`.
    pub result_cut: bool,
}
