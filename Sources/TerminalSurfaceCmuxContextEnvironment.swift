import Foundation

struct TerminalSurfaceCmuxContextEnvironment: Equatable, Sendable {
    let workspaceId: UUID
    let surfaceId: UUID
    let socketPath: String
    /// Absolute path to this workspace's Notes tree root (resolved, not
    /// necessarily created), exported as `CMUX_WORKSPACE_NOTES_DIR` so the
    /// `cmux-notes` skill can target it. `nil` when unresolved (e.g. remote).
    var workspaceNotesDir: String? = nil
}
