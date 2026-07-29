mod client;
mod handles;
mod id;
mod model;
mod ops;
mod options;
mod stream;
mod typed_stream;
mod wire;

pub use client::{Client, Config};
pub use handles::{
    Agent, Browser, ConnectedClient, FrontendProjection, Machine, Notification, PairingRequest,
    Pane, ProviderAction, ProviderNotice, ProviderScope, Screen, Session, SidebarView, Tab,
    Terminal, Workspace,
};
pub use id::{
    AgentId, BrowserId, ConnectedClientId, FrontendProjectionId, MachineId, NotificationId,
    OpaqueId, PairingRequestId, PaneId, ProviderActionId, ProviderNoticeId, ProviderScopeId,
    ScreenId, Selector, SessionId, SidebarViewId, SplitId, StreamId, TabId, TerminalId,
    WorkspaceId,
};
pub use model::{
    AgentSnapshot, BrowserSnapshot, ConnectedClientSnapshot, Created, CreatedPath, Cursor,
    Document, FrontendProjectionSnapshot, MachineSnapshot, MutationReceipt, MutationResult,
    NotificationSnapshot, PairingRequestSnapshot, PaneSnapshot, ParentIds, ProtocolFailure,
    ProviderActionSnapshot, ProviderNoticeSnapshot, ProviderScopeSnapshot, RendererGrant,
    ResourceSnapshot, ScreenSnapshot, SessionSnapshot, SidebarViewSnapshot, Snapshot, StreamEnd,
    StreamEndReason, TabSnapshot, TerminalSnapshot, WorkspaceSnapshot,
};
pub use options::{
    AgentListOptions, AgentReportOptions, AgentSource, AgentState, BrowserAttachOptions,
    BrowserCreateOptions, BrowserKeyKind, BrowserKeyOptions, BrowserMouseButton, BrowserMouseKind,
    BrowserMouseOptions, CellPixelsOptions, ClientMetadataOptions, ClientSizingOptions, CopyMode,
    CopyOptions, CreatePaneOptions, CreateScreenOptions, CreateWorkspaceOptions, CursorStyle,
    Direction, EventStreamOptions, FocusInputOptions, InitialContent, InputModifier, LabelOptions,
    LayoutOptions, MachineConnectOptions, MachineRenameOptions, MouseButton, MoveDestination,
    MutationOptions, NavigateOptions, NotificationLevel, NotificationListOptions,
    NotificationOptions, PairingDecision, PairingResolveOptions, PaneSwapOptions, PixelSize,
    ProjectionOptions, ProviderActionOptions, ProviderActionValue, ReadHistoryOptions,
    ReadScreenOptions, RendererGrantOptions, RunCommand, RunOptions, ScrollOptions,
    SessionOpenOptions, ShutdownOptions, SidebarEnsureOptions, SidebarInputOptions, Size,
    SplitOptions, SplitRatioOptions, TerminalAttachOptions, TerminalCreateOptions,
    TerminalDefaultsOptions, TerminalKeysOptions, TerminalMouseKind, TerminalMouseOptions,
    TextInputOptions, UndoLayoutOptions, Update, ViewportWidthOptions, WaitOptions, WheelOptions,
    ZoomOptions,
};
pub use stream::StreamCancellation;
pub use typed_stream::{
    BrowserAttachment, BrowserAttachmentItem, BrowserFrameMime, ColorHex, ProviderNoticeItem,
    ProviderNoticeRecord, ProviderNoticeStream, RenderCursor, RenderCursorStyle, RenderPatch,
    RenderRow, RenderRun, RenderScroll, RenderSnapshot, RenderUnderline, ResetReason,
    ResourceChange, ResourceKind, ResourceReference, SessionDeltaEvent, SessionEvent,
    SessionEventStream, SessionSnapshotEvent, SidebarViewItem, SidebarViewStream,
    TerminalAttachment, TerminalAttachmentItem,
};
