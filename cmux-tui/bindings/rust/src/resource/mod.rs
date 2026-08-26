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
    Pane, Screen, Session, SessionCreation, SidebarView, Tab, Terminal, Workspace,
};
pub use id::{
    AgentId, BrowserId, ConnectedClientId, FrontendProjectionId, MachineId, NotificationId,
    OpaqueId, PairingRequestId, PaneId, ScreenId, Selector, SessionId, SidebarViewId, SplitId,
    StreamId, TabId, TerminalId, WorkspaceId,
};
pub use model::{
    AgentSnapshot, AgentSnapshotSource, BrowserSnapshot, BrowserSource, BrowserStatus,
    BrowserViewerResizeResult, CellPixelsResult, ClientSnapshot, ClientTerminalSize,
    ClientTransport, ConfirmationRequiredDetails, ConnectedClientSnapshot, Created, CreatedPath,
    CreationRecovery, CreationResolution, CreationState, Cursor, Document,
    FrontendProjectionSnapshot, LayoutColumn, LayoutDirection, LayoutDocument, LayoutLeaf,
    LayoutNode, LayoutSplit, LayoutStack, LayoutViewport, MachineOrigin, MachineSnapshot,
    MachineStatus, MutationReceipt, MutationResult, NotificationSnapshot, PairingCode,
    PairingRequestSnapshot, PairingResolutionResult, PairingStatus, PaneNeighborResult,
    PaneSnapshot, PingResult, ProcessInfoResult, ProtocolFailure, ReloadConfigResult,
    RendererGrant, ResourceEntitySnapshot, ResourceSnapshot, ScreenSnapshot, SessionSnapshot,
    ShutdownResult, SidebarViewSnapshot, StreamEnd, StreamEndReason, StreamPoll, TabContentId,
    TabContentKind, TabSnapshot, TerminalCopyResult, TerminalDefaultsSnapshot, TerminalExit,
    TerminalExitOutcome, TerminalExitedLifecycle, TerminalHistoryResult, TerminalLifecycle,
    TerminalPendingLifecycle, TerminalScreenResult, TerminalSnapshot, TerminalStateResult,
    TerminalWaitExitExited, TerminalWaitExitPending, TerminalWaitExitResult, TerminalWaitResult,
    TypedStreamItem, ViewAttachmentOutcome, ViewerReleaseResult, ViewerResizeResult,
    WorkspaceSnapshot,
};
pub use options::{
    AgentListOptions, AgentReportOptions, AgentSource, AgentState, BrowserAttachOptions,
    BrowserCreateOptions, BrowserKeyKind, BrowserKeyOptions, BrowserMouseButton, BrowserMouseKind,
    BrowserMouseOptions, CancellationToken, CellPixelsOptions, ClientMetadataOptions,
    ClientSizingOptions, CopyMode, CopyOptions, CreatePaneOptions, CreateScreenOptions,
    CreateWorkspaceOptions, CursorStyle, Direction, EventStreamOptions, FocusInputOptions,
    InitialContent, InputModifier, JournalStart, JournalSubjectFilter, LabelOptions, LayoutOptions,
    MouseButton, MoveDestination, MutationOptions, NavigateOptions, NotificationLevel,
    NotificationListOptions, NotificationOptions, PairingDecision, PairingResolveOptions,
    PaneSwapOptions, PixelSize, ProjectionOptions, ReadHistoryOptions, ReadScreenOptions,
    RendererGrantOptions, RequestOptions, RunCommand, RunOptions, ScrollOptions,
    SessionJournalOptions, SessionOpenOptions, ShutdownOptions, SidebarEnsureOptions,
    SidebarInputOptions, Size, SplitOptions, SplitRatioOptions, TerminalAttachOptions,
    TerminalCreateOptions, TerminalDefaultsOptions, TerminalKeysOptions, TerminalMouseKind,
    TerminalMouseOptions, TerminalProjectOptions, TextInputOptions, UndoLayoutOptions, Update,
    ViewportWidthOptions, WaitOptions, WheelOptions, ZoomOptions,
};
pub use stream::StreamCancellation;
pub use typed_stream::{
    BrowserAttachment, BrowserAttachmentItem, BrowserFrameMime, ColorHex, JournalAuthority,
    JournalClass, JournalProducer, JournalReplayPolicy, JournalSensitivity, JournalSubject,
    RenderCursor, RenderCursorStyle, RenderPatch, RenderRow, RenderRun, RenderScroll,
    RenderSnapshot, RenderUnderline, ResetReason, ResourceChange, ResourceKind, ResourceReference,
    SessionDeltaEvent, SessionEvent, SessionEventStream, SessionJournalRecord,
    SessionJournalStream, SessionSnapshotEvent, SidebarViewItem, SidebarViewStream,
    TerminalAttachment, TerminalAttachmentItem,
};
