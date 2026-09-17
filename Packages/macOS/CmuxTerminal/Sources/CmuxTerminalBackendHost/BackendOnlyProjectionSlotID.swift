internal import CmuxTerminalBackend
internal import Foundation

/// Identifies one reusable pane runtime independently of its selected tab.
nonisolated struct BackendOnlyProjectionSlotID: Equatable, Hashable, Sendable {
    let logicalPresentationID: UUID
    let workspaceID: WorkspaceID
    let screenID: ScreenID
    let paneID: PaneID
}
