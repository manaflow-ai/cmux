//! Typed shared-state calls on the handles: `workspace.update`, `tab.pin`,
//! `tab.unpin`, `tab.update`, `column.update`, `window_record.*`,
//! `workspace.ensure_home`, the personal workspace groups
//! (`workspace_group.*`, `workspace.place`, `workspace.placement.list`),
//! closed history (`closed.*`), tab groups (`tab_group.*`), and saved tab
//! groups (`saved_tab_group.*`).

#[path = "closed.rs"]
mod closed;
#[path = "column_update.rs"]
mod column_update;
#[path = "home.rs"]
mod home;
#[path = "saved_tab_groups.rs"]
mod saved_tab_groups;
#[path = "tab_groups.rs"]
mod tab_groups;
#[path = "tab_update.rs"]
mod tab_update;
#[path = "window_records.rs"]
mod window_records;
#[path = "workspace_groups.rs"]
mod workspace_groups;
#[path = "workspace_update.rs"]
mod workspace_update;

pub use closed::{
    ClosedItemSnapshot, ClosedListOptions, ClosedMemberRecord, ClosedReopenOptions,
    ClosedReopenResult, ClosedScreenRecord, ClosedTabRecord,
};
pub use column_update::{ColumnEdge, ColumnMode};
pub use home::CONVERSATION_TABS_CAPABILITY;
pub use saved_tab_groups::{
    SavedTabGroupReopenResult, SavedTabGroupSnapshot, SavedTabMemberSnapshot, StateDeleteResult,
};
pub use tab_groups::{
    TAB_GROUP_MAX_TABS, TabGroupCreateOptions, TabGroupMoveOptions, TabGroupReleaseResult,
    TabGroupSnapshot, TabGroupUpdateOptions,
};
pub use tab_update::{TAB_HISTORY_MAX_URLS, TabUpdateOptions};
pub use window_records::{WINDOW_RECORD_MAX_BYTES, WindowRecordDeleteResult, WindowRecordSnapshot};
pub use workspace_groups::{
    WorkspaceGroupCreateOptions, WorkspaceGroupDeleteResult, WorkspaceGroupSnapshot,
    WorkspaceGroupUpdateOptions, WorkspacePlaceOptions, WorkspacePlacementSnapshot, WorkspaceRef,
};
pub use workspace_update::WorkspaceUpdateOptions;
