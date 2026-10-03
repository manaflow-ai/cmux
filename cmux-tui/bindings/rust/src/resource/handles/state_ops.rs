//! Typed shared-state calls on the handles: `workspace.update`, `tab.pin`,
//! `tab.unpin`, `tab.update`, `column.update`, and `window_record.*`.

#[path = "column_update.rs"]
mod column_update;
#[path = "tab_update.rs"]
mod tab_update;
#[path = "window_records.rs"]
mod window_records;
#[path = "workspace_update.rs"]
mod workspace_update;

pub use column_update::{ColumnEdge, ColumnMode};
pub use tab_update::{TAB_HISTORY_MAX_URLS, TabUpdateOptions};
pub use window_records::{WINDOW_RECORD_MAX_BYTES, WindowRecordDeleteResult, WindowRecordSnapshot};
pub use workspace_update::WorkspaceUpdateOptions;
