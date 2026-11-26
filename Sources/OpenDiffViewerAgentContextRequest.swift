import Foundation

struct OpenDiffViewerAgentContextRequest: Sendable {
    let cliURL: URL
    let socketPath: String
    let fallbackCwd: String
    let snapshotWorkingDirectory: String?
    let storeURL: URL
    let workspaceId: UUID
    let surfaceId: UUID
    let sessionId: String
    let originWindowId: UUID?
}
