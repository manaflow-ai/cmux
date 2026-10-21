//! The gate on the Chief's own tools in a turn that asks. They run without a
//! permission request (approval.rs `own_tools`), so the host checks each
//! `send`, `profile`, `tell` and `control` call at the tools socket instead,
//! with the rule a permission request had (`Brain::internal_allowed`).

use serde_json::{Value, json};

use super::Brain;

impl Brain {
    /// Ok when the running turn may make this call of its own tool `tool`
    /// with `input` (the tool's arguments); else why not, as the tool's
    /// error. A turn that does not ask may make every call.
    pub(super) fn own_tool_gate(&self, tool: &str, input: &Value) -> Result<(), String> {
        let request = json!({"toolCall": {"title": tool, "rawInput": input}});
        if self.internal_allowed(tool, &request) {
            return Ok(());
        }
        let why = match &self.turn_why {
            Some(crate::approval::Why::Device(device)) => format!("it started from {device}"),
            Some(crate::approval::Why::Participant) => {
                "someone else in this conversation asked".to_owned()
            }
            Some(crate::approval::Why::Home) => "it read the Home screens".to_owned(),
            None => "it needs approvals".to_owned(),
        };
        let what = crate::approval::describe(tool, Some(input));
        Err(format!(
            "not run: this turn asks before local actions ({why}), so it may not {what}. Tell the owner what you wanted to do; they can ask for it themselves."
        ))
    }
}
