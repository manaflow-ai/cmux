//! The two user settings for subagent workspaces, read from the user's cmux
//! settings file (`~/.config/cmux/cmux-next.json`, else `cmux.json`; the
//! Settings window, `cmux settings` and the palette write it) at each use, so
//! a change applies to the next spawn or finish:
//!
//! - `subagents.showWorkspaces`: each subagent gets a sidebar workspace when
//!   it starts. Unset there: this Chief's own `optchat/settings.json` value
//!   (`chief settings set`), else false. Before 2026-11-05 the host read only
//!   that per-Chief file, so `cmux settings set subagents.showWorkspaces
//!   true` wrote a value nothing read and the setting looked like it went
//!   back to false on its own (Aziz 2026-11-05).
//!   It is the older show-all switch: on, every subagent shows, whatever the
//!   Chief or the `chief.subagentSidebar` rules choose (sidebar_choice.rs,
//!   action_lifetime.rs).
//! - `subagents.closeFinishedWorkspaces`: a finished subagent's workspace
//!   closes (fewer workspaces in the sidebar). Default false: only a tucked
//!   workspace (the collapsed "Chief" group, action_lifetime.rs) closes when
//!   its work ends; any other stays until the person closes it. Replaces the
//!   `OPTCHAT_SUBAGENT_ON_FINISH=close` environment variable.
//!
//! Telemetry (the monitoring trace, trace.rs): `setting.changed` when the
//! effective `subagents.showWorkspaces` or its source changes, and
//! `subagent.workspace_closed` with its reason (`close_finished_setting`,
//! `tucked_reaper`, `superseded`, `control_hide`) for every close the host
//! makes on its own.

use serde_json::{Value, json};

use super::Brain;

/// The user settings key that shows a subagent's workspace at start.
pub const SHOW_WORKSPACES: &str = "subagents.showWorkspaces";

/// The user settings key that closes a finished subagent's workspace.
pub const CLOSE_FINISHED: &str = "subagents.closeFinishedWorkspaces";

/// Where the effective `subagents.showWorkspaces` came from.
pub const SOURCE_USER_FILE: &str = "cmux_settings_file";
pub const SOURCE_CHIEF_FILE: &str = "chief_settings";

/// A boolean key of the user's settings document, nested or flat.
pub fn user_bool(doc: Option<&Value>, key: &str) -> Option<bool> {
    doc.and_then(|d| crate::agent_memory::settings::value(d, key))
        .and_then(|v| v.as_bool())
}

impl Brain {
    /// Whether a subagent starting now gets its sidebar workspace: the user's
    /// file, else this Chief's settings. Traces a change of value or source.
    pub(super) fn show_subagent_workspaces(&mut self) -> bool {
        let doc = self.user_settings_doc();
        let (value, source) = match user_bool(doc.as_ref(), SHOW_WORKSPACES) {
            Some(v) => (v, SOURCE_USER_FILE),
            None => (self.chief.show_subagent_workspaces, SOURCE_CHIEF_FILE),
        };
        if self.last_show_workspaces != Some((value, source)) {
            let previous = self.last_show_workspaces.map(|(v, _)| v);
            self.trace.emit(
                "setting.changed",
                json!({"key": SHOW_WORKSPACES, "value": value, "previous": previous, "source": source}),
            );
            (self.log)(&format!(
                "{SHOW_WORKSPACES} = {value} (from {source}; was {})",
                previous.map_or("unread".to_owned(), |v| v.to_string())
            ));
            self.last_show_workspaces = Some((value, source));
        }
        value
    }

    /// Whether a finished subagent's workspace closes (the user's opt-in).
    pub(super) fn close_finished_subagent_workspaces(&self) -> bool {
        user_bool(self.user_settings_doc().as_ref(), CLOSE_FINISHED).unwrap_or(false)
    }

    /// Traces a workspace close the host makes on its own, with its reason.
    pub(super) fn trace_workspace_close(&self, id: &str, reason: &str) {
        trace_close(&self.trace, &self.log, id, reason);
    }
}

/// `subagent.workspace_closed {id, reason}` in the trace, and a log line.
pub(super) fn trace_close(trace: &crate::trace::Trace, log: &super::Log, id: &str, reason: &str) {
    trace.emit(
        "subagent.workspace_closed",
        json!({"id": id, "reason": reason}),
    );
    log(&format!("subagent {id}: closed its workspace ({reason})"));
}
