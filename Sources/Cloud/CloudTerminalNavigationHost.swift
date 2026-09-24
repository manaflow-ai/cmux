import Foundation

/// App-owned presentation effects used after catalog navigation succeeds or is cancelled.
@MainActor
struct CloudTerminalNavigationHost {
    var focus: @MainActor (_ panelID: UUID, _ workspaceID: UUID) -> Void
    var closeWorkspace: @MainActor (UUID) -> Void
}
