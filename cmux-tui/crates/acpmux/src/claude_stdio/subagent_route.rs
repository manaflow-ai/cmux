//! The session a claude line's updates go to. A subagent's lines carry its
//! Agent tool call's id (`parent_tool_use_id`) and stream under its own
//! session, `<acp>/<toolu>` (ACP draft #1992), the id `spawn_subagent` gave
//! it. That holds after the translator stopped tracking it too: a background
//! subagent can write after its `task_notification`, and a foreground one
//! after a cancelled turn dropped it. Under the main session its text and
//! tool calls read as the main agent's (the chief's posted reply, the chat).
//! The hub keeps every subagent it saw (`crate::subagents`), so an ended
//! one's update still lands in that subagent's own view.

use super::*;

impl Translator {
    /// The session id for the updates of a line with this `parent_tool_use_id`.
    pub(super) fn line_session(&self, parent: Option<&str>) -> String {
        match parent {
            Some(tool) => format!("{}/{tool}", self.acp_session_id),
            None => self.acp_session_id.clone(),
        }
    }
}
