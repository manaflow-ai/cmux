import Foundation

/// App-owned presentation effects used after catalog navigation succeeds or is cancelled.
@MainActor
public struct CloudTerminalNavigationHost: Sendable {
    public init(
        focus: @escaping @MainActor (_ panelID: UUID, _ workspaceID: UUID) -> Void,
        closeWorkspace: @escaping @MainActor (UUID) -> Void
    ) {
        self.focus = focus
        self.closeWorkspace = closeWorkspace
    }

    public var focus: @MainActor (_ panelID: UUID, _ workspaceID: UUID) -> Void
    public var closeWorkspace: @MainActor (UUID) -> Void
}
