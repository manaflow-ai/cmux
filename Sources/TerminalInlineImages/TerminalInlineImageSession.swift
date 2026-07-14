import Foundation

/// Immutable identity and weak workspace context for one visible terminal surface.
@MainActor
final class TerminalInlineImageSession {
    let id = UUID()
    let surfaceID: UUID
    let workspaceID: UUID
    weak var workspace: Workspace?

    init(surfaceID: UUID, workspace: Workspace) {
        self.surfaceID = surfaceID
        self.workspaceID = workspace.id
        self.workspace = workspace
    }

    func matches(surfaceID: UUID, workspace: Workspace) -> Bool {
        self.surfaceID == surfaceID && self.workspace === workspace
    }
}
