import Foundation

struct TerminalSurfaceCmuxContextEnvironment: Equatable, Sendable {
    let workspaceId: UUID
    let surfaceId: UUID
    let socketPath: String
}
