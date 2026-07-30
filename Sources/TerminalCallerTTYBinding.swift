import Foundation

nonisolated struct TerminalCallerTTYBinding: Equatable, Hashable, Sendable {
    let workspaceId: UUID
    let surfaceId: UUID
}
