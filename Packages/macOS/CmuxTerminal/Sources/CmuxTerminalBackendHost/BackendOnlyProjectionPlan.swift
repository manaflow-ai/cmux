internal import CmuxTerminalBackend
internal import Foundation

/// An atomic visible-window projection derived from canonical daemon state.
nonisolated struct BackendOnlyProjectionPlan: Equatable, Sendable {
    let logicalPresentationID: UUID
    let workspaceID: WorkspaceID
    let numericWorkspaceID: UInt64
    let workspaceName: String
    let screenID: ScreenID
    let numericScreenID: UInt64
    let screenName: String?
    let activePaneID: PaneID
    let zoomedPaneID: PaneID?
    let layout: BackendOnlyProjectionLayout
    let panes: [BackendOnlyProjectionPaneDescriptor]
    let metrics: BackendOnlyProjectionPlannerMetrics
}
