const std = @import("std");

pub const raw = @import("raw.zig");
pub const resource = @import("resource.zig");

pub const Operation = resource.Operation;
pub const OperationClass = resource.OperationClass;
pub const Client = resource.Client;
pub const Options = resource.Options;
pub const MutationOptions = resource.MutationOptions;
pub const ExactCommand = resource.ExactCommand;
pub const ShellCommand = resource.ShellCommand;
pub const RunCommand = resource.RunCommand;
pub const RunOptions = resource.RunOptions;
pub const TerminalHistoryOptions = resource.TerminalHistoryOptions;
pub const CreateTerminalTabOptions = resource.CreateTerminalTabOptions;
pub const CreateBrowserTabOptions = resource.CreateBrowserTabOptions;
pub const InitialContent = resource.InitialContent;
pub const CreateWorkspaceOptions = resource.CreateWorkspaceOptions;
pub const UndoLayoutOptions = resource.UndoLayoutOptions;
pub const ClientMetadataUpdate = resource.ClientMetadataUpdate;
pub const OptionalStringUpdate = resource.OptionalStringUpdate;
pub const Cursor = resource.Cursor;
pub const CreatedPath = resource.CreatedPath;
pub const CreatedWorkspaceOnly = resource.CreatedWorkspaceOnly;
pub const CreatedTerminalPath = resource.CreatedTerminalPath;
pub const CreatedBrowserPath = resource.CreatedBrowserPath;
pub const ResourceError = resource.ResourceError;
pub const OwnedResourceError = resource.OwnedResourceError;
pub const MutationTransportCause = resource.MutationTransportCause;
pub const MutationTransportUncertain =
    resource.MutationTransportUncertain;
pub const OwnedMutationTransportUncertain =
    resource.OwnedMutationTransportUncertain;
pub const ResourceErrorDetails = resource.ResourceErrorDetails;
pub const ErrorResourceScope = resource.ErrorResourceScope;
pub const ErrorResourceId = resource.ErrorResourceId;
pub const MutationRecovery = resource.MutationRecovery;
pub const ConfirmationRequiredDetails =
    resource.ConfirmationRequiredDetails;
pub const CreationConflictDetails = resource.CreationConflictDetails;
pub const CursorGapDetails = resource.CursorGapDetails;
pub const CursorInvalidDetails = resource.CursorInvalidDetails;
pub const IdempotencyConflictDetails =
    resource.IdempotencyConflictDetails;
pub const LocalIoDetails = resource.LocalIoDetails;
pub const MutationIndeterminateDetails =
    resource.MutationIndeterminateDetails;
pub const OperationFailedDetails = resource.OperationFailedDetails;
pub const ResourceNotFoundDetails = resource.ResourceNotFoundDetails;
pub const RevisionConflictDetails = resource.RevisionConflictDetails;
pub const SelectorAmbiguousDetails = resource.SelectorAmbiguousDetails;
pub const SelectorInvalidDetails = resource.SelectorInvalidDetails;
pub const SelectorNotFoundDetails = resource.SelectorNotFoundDetails;
pub const SelectorWrongParentDetails =
    resource.SelectorWrongParentDetails;
pub const TransportClosedDetails = resource.TransportClosedDetails;
pub const ValidationInvalidDetails = resource.ValidationInvalidDetails;
pub const UnrecognizedResourceErrorDetails =
    resource.UnrecognizedResourceErrorDetails;
pub const MalformedResourceErrorDetails =
    resource.MalformedResourceErrorDetails;
pub const SensitiveString = resource.SensitiveString;
pub const RendererGrant = resource.RendererGrant;
pub const RendererGrantOptions = resource.RendererGrantOptions;
pub const MachineId = resource.MachineId;
pub const SessionId = resource.SessionId;
pub const WorkspaceId = resource.WorkspaceId;
pub const ScreenId = resource.ScreenId;
pub const PaneId = resource.PaneId;
pub const TabId = resource.TabId;
pub const TerminalId = resource.TerminalId;
pub const BrowserId = resource.BrowserId;
pub const ConnectedClientId = resource.ConnectedClientId;
pub const SplitId = resource.SplitId;
pub const NotificationId = resource.NotificationId;
pub const AgentId = resource.AgentId;
pub const StreamId = resource.StreamId;
pub const FrontendProjectionId = resource.FrontendProjectionId;
pub const PairingRequestId = resource.PairingRequestId;
pub const SidebarViewId = resource.SidebarViewId;
pub const SidebarPluginId = resource.SidebarPluginId;
pub const Selector = resource.Selector;
pub const ResourceSnapshot = resource.ResourceSnapshot;
pub const MachineOrigin = resource.MachineOrigin;
pub const MachineStatus = resource.MachineStatus;
pub const MachineSnapshot = resource.MachineSnapshot;
pub const SessionSnapshot = resource.SessionSnapshot;
pub const WorkspaceSnapshot = resource.WorkspaceSnapshot;
pub const ClientTransport = resource.ClientTransport;
pub const ClientTerminalSize = resource.ClientTerminalSize;
pub const ClientSnapshot = resource.ClientSnapshot;
pub const BrowserSource = resource.BrowserSource;
pub const BrowserStatus = resource.BrowserStatus;
pub const BrowserSnapshot = resource.BrowserSnapshot;
pub const PixelSize = resource.PixelSize;
pub const BrowserViewerResizeResult =
    resource.BrowserViewerResizeResult;
pub const ViewAttachmentOutcome = resource.ViewAttachmentOutcome;
pub const ViewerReleaseResult = resource.ViewerReleaseResult;
pub const CellPixelFailure = resource.CellPixelFailure;
pub const CellPixelsResult = resource.CellPixelsResult;
pub const LayoutDirection = resource.LayoutDirection;
pub const LayoutLeaf = resource.LayoutLeaf;
pub const LayoutSplit = resource.LayoutSplit;
pub const LayoutStack = resource.LayoutStack;
pub const LayoutColumn = resource.LayoutColumn;
pub const LayoutViewport = resource.LayoutViewport;
pub const UnknownLayoutNode = resource.UnknownLayoutNode;
pub const LayoutNode = resource.LayoutNode;
pub const LayoutDocument = resource.LayoutDocument;
pub const ScreenSnapshot = resource.ScreenSnapshot;
pub const PaneSnapshot = resource.PaneSnapshot;
pub const TabContentKind = resource.TabContentKind;
pub const TabContentId = resource.TabContentId;
pub const TabSnapshot = resource.TabSnapshot;
pub const EmptyResult = resource.EmptyResult;
pub const PingResult = resource.PingResult;
pub const RenderUnderline = resource.RenderUnderline;
pub const RenderRun = resource.RenderRun;
pub const RenderRow = resource.RenderRow;
pub const TerminalScreenResult = resource.TerminalScreenResult;
pub const TerminalStateResult = resource.TerminalStateResult;
pub const TerminalHistoryResult = resource.TerminalHistoryResult;
pub const TerminalWaitResult = resource.TerminalWaitResult;
pub const TerminalCopyMode = resource.TerminalCopyMode;
pub const TerminalCopyResult = resource.TerminalCopyResult;
pub const ProcessInfoResult = resource.ProcessInfoResult;
pub const Size = resource.Size;
pub const ViewerResizeResult = resource.ViewerResizeResult;
pub const ProjectionPutOptions = resource.ProjectionPutOptions;
pub const OwnedMachineSnapshot = resource.OwnedMachineSnapshot;
pub const OwnedSessionSnapshot = resource.OwnedSessionSnapshot;
pub const OwnedWorkspaceSnapshot = resource.OwnedWorkspaceSnapshot;
pub const OwnedClientSnapshot = resource.OwnedClientSnapshot;
pub const OwnedBrowserSnapshot = resource.OwnedBrowserSnapshot;
pub const OwnedScreenSnapshot = resource.OwnedScreenSnapshot;
pub const OwnedPaneSnapshot = resource.OwnedPaneSnapshot;
pub const OwnedTabSnapshot = resource.OwnedTabSnapshot;
pub const OwnedPingResult = resource.OwnedPingResult;
pub const OwnedEmptyResult = resource.OwnedEmptyResult;
pub const OwnedTerminalScreenResult =
    resource.OwnedTerminalScreenResult;
pub const OwnedTerminalStateResult =
    resource.OwnedTerminalStateResult;
pub const OwnedTerminalHistoryResult =
    resource.OwnedTerminalHistoryResult;
pub const OwnedTerminalWaitResult = resource.OwnedTerminalWaitResult;
pub const OwnedTerminalCopyResult = resource.OwnedTerminalCopyResult;
pub const OwnedProcessInfoResult = resource.OwnedProcessInfoResult;
pub const OwnedViewerResizeResult = resource.OwnedViewerResizeResult;
pub const OwnedViewerReleaseResult = resource.OwnedViewerReleaseResult;
pub const OwnedBrowserViewerResizeResult =
    resource.OwnedBrowserViewerResizeResult;
pub const OwnedCellPixelsResult = resource.OwnedCellPixelsResult;
pub const MachineList = resource.MachineList;
pub const SessionList = resource.SessionList;
pub const WorkspaceList = resource.WorkspaceList;
pub const WorkspaceMutationResult = resource.WorkspaceMutationResult;
pub const BrowserMutationResult = resource.BrowserMutationResult;
pub const ScreenMutationResult = resource.ScreenMutationResult;
pub const PaneMutationResult = resource.PaneMutationResult;
pub const TabMutationResult = resource.TabMutationResult;
pub const CreatedPathMutationResult =
    resource.CreatedPathMutationResult;
pub const CreatedTerminalPathMutationResult =
    resource.CreatedTerminalPathMutationResult;
pub const CreatedBrowserPathMutationResult =
    resource.CreatedBrowserPathMutationResult;
pub const EmptyMutationResult = resource.EmptyMutationResult;
pub const Machine = resource.Machine;
pub const Session = resource.Session;
pub const Workspace = resource.Workspace;
pub const Screen = resource.Screen;
pub const Pane = resource.Pane;
pub const Tab = resource.Tab;
pub const Terminal = resource.Terminal;
pub const Browser = resource.Browser;
pub const ConnectedClient = resource.ConnectedClient;
pub const PairingRequest = resource.PairingRequest;
pub const FrontendProjection = resource.FrontendProjection;
pub const SidebarView = resource.SidebarView;
pub const ResetReason = resource.ResetReason;
pub const ResourceKind = resource.ResourceKind;
pub const ResourceReference = resource.ResourceReference;
pub const ResourceUpsert = resource.ResourceUpsert;
pub const ResourceDelete = resource.ResourceDelete;
pub const ResourceChange = resource.ResourceChange;
pub const UnknownDiscriminated = resource.UnknownDiscriminated;
pub const SessionSnapshotEvent = resource.SessionSnapshotEvent;
pub const SessionDeltaEvent = resource.SessionDeltaEvent;
pub const SessionEvent = resource.SessionEvent;
pub const TerminalAttachmentItem = resource.TerminalAttachmentItem;
pub const BrowserAttachmentItem = resource.BrowserAttachmentItem;
pub const SidebarViewItem = resource.SidebarViewItem;
pub const StreamEnd = resource.StreamEnd;
pub const StreamEndReason = resource.StreamEndReason;
pub const SessionEventStream = resource.SessionEventStream;
pub const TerminalAttachmentStream = resource.TerminalAttachmentStream;
pub const BrowserAttachmentStream = resource.BrowserAttachmentStream;
pub const SidebarViewStream = resource.SidebarViewStream;
pub const ConnectionFactory = resource.ConnectionFactory;
pub const ResourceEntitySnapshot = resource.ResourceEntitySnapshot;
pub const RenderCursorStyle = resource.RenderCursorStyle;
pub const RenderCursor = resource.RenderCursor;
pub const RenderSnapshot = resource.RenderSnapshot;
pub const RenderPatch = resource.RenderPatch;
pub const RenderScroll = resource.RenderScroll;
pub const BrowserFrameMime = resource.BrowserFrameMime;
pub const CreateScreenOptions = resource.CreateScreenOptions;
pub const CreatePaneOptions = resource.CreatePaneOptions;
pub const Direction = resource.Direction;
pub const SplitOptions = resource.SplitOptions;
pub const MoveDestination = resource.MoveDestination;
pub const TerminalProjectOptions = resource.TerminalProjectOptions;
pub const TerminalMouseKind = resource.TerminalMouseKind;
pub const BrowserKeyKind = resource.BrowserKeyKind;
pub const BrowserMouseKind = resource.BrowserMouseKind;
pub const InputModifier = resource.InputModifier;
pub const TerminalMouseOptions = resource.TerminalMouseOptions;
pub const BrowserKeyOptions = resource.BrowserKeyOptions;
pub const BrowserMouseOptions = resource.BrowserMouseOptions;
pub const BrowserWheelOptions = resource.BrowserWheelOptions;
pub const TerminalAttachOptions = resource.TerminalAttachOptions;
pub const BrowserAttachOptions = resource.BrowserAttachOptions;
pub const NotificationListOptions = resource.NotificationListOptions;
pub const NotificationCreateOptions = resource.NotificationCreateOptions;
pub const AgentListOptions = resource.AgentListOptions;
pub const AgentReportOptions = resource.AgentReportOptions;
pub const SidebarEnsureOptions = resource.SidebarEnsureOptions;
pub const RendererGrantRequest = resource.RendererGrantRequest;
pub const TerminalDefaultsUpdate = resource.TerminalDefaultsUpdate;
pub const CursorStyle = resource.CursorStyle;
pub const OptionalCursorStyleUpdate =
    resource.OptionalCursorStyleUpdate;
pub const OptionalBoolUpdate = resource.OptionalBoolUpdate;
pub const OptionalPaletteUpdate = resource.OptionalPaletteUpdate;
pub const TerminalExitOutcome = resource.TerminalExitOutcome;
pub const TerminalExit = resource.TerminalExit;
pub const TerminalLifecycle = resource.TerminalLifecycle;
pub const TerminalSnapshot = resource.TerminalSnapshot;
pub const NotificationLevel = resource.NotificationLevel;
pub const NotificationSnapshot = resource.NotificationSnapshot;
pub const AgentState = resource.AgentState;
pub const AgentSource = resource.AgentSource;
pub const AgentSnapshot = resource.AgentSnapshot;
pub const PairingStatus = resource.PairingStatus;
pub const PairingDecision = resource.PairingDecision;
pub const PairingRequestSnapshot = resource.PairingRequestSnapshot;
pub const PairingResolutionResult = resource.PairingResolutionResult;
pub const FrontendProjectionSnapshot =
    resource.FrontendProjectionSnapshot;
pub const SidebarViewSnapshot = resource.SidebarViewSnapshot;
pub const CreationState = resource.CreationState;
pub const CreationRecovery = resource.CreationRecovery;
pub const CreationResolution = resource.CreationResolution;
pub const TerminalWaitExitPending = resource.TerminalWaitExitPending;
pub const TerminalWaitExitExited = resource.TerminalWaitExitExited;
pub const TerminalWaitExitResult = resource.TerminalWaitExitResult;
pub const PaneNeighborResult = resource.PaneNeighborResult;
pub const ShutdownResult = resource.ShutdownResult;
pub const ReloadConfigResult = resource.ReloadConfigResult;
pub const TerminalDefaultsSnapshot = resource.TerminalDefaultsSnapshot;
pub const OwnedTerminalSnapshot = resource.OwnedTerminalSnapshot;
pub const OwnedTerminalWaitExitResult =
    resource.OwnedTerminalWaitExitResult;
pub const OwnedPaneNeighborResult = resource.OwnedPaneNeighborResult;
pub const OwnedCreationResolution = resource.OwnedCreationResolution;
pub const OwnedResourceSnapshot = resource.OwnedResourceSnapshot;
pub const OwnedReloadConfigResult = resource.OwnedReloadConfigResult;
pub const OwnedLayoutDocument = resource.OwnedLayoutDocument;
pub const OwnedFrontendProjectionSnapshot =
    resource.OwnedFrontendProjectionSnapshot;
pub const OwnedSidebarViewSnapshot =
    resource.OwnedSidebarViewSnapshot;
pub const OwnedPairingResolutionResult =
    resource.OwnedPairingResolutionResult;
pub const ScreenList = resource.ScreenList;
pub const PaneList = resource.PaneList;
pub const TabList = resource.TabList;
pub const TerminalList = resource.TerminalList;
pub const BrowserList = resource.BrowserList;
pub const ClientList = resource.ClientList;
pub const NotificationList = resource.NotificationList;
pub const AgentList = resource.AgentList;
pub const PairingRequestList = resource.PairingRequestList;
pub const SessionMutationResult = resource.SessionMutationResult;
pub const TerminalMutationResult = resource.TerminalMutationResult;
pub const NotificationMutationResult =
    resource.NotificationMutationResult;
pub const AgentMutationResult = resource.AgentMutationResult;
pub const PairingResolutionMutationResult =
    resource.PairingResolutionMutationResult;
pub const FrontendProjectionMutationResult =
    resource.FrontendProjectionMutationResult;
pub const SidebarViewMutationResult =
    resource.SidebarViewMutationResult;
pub const ShutdownMutationResult = resource.ShutdownMutationResult;
pub const ReloadConfigMutationResult =
    resource.ReloadConfigMutationResult;
pub const TerminalDefaultsMutationResult =
    resource.TerminalDefaultsMutationResult;

test {
    std.testing.refAllDecls(resource);
    std.testing.refAllDecls(raw);
}
