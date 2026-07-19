internal import CmuxTerminalBackend
internal import Foundation

/// The minimal projection-navigation v2 value consumed by the pure planner.
nonisolated struct BackendOnlyProjectionNavigationInput: Equatable, Sendable {
    let logicalPresentationID: UUID
    let selectedWorkspaceID: WorkspaceID?
    let workspaces: [BackendOnlyProjectionWorkspaceNavigation]
}
