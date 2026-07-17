import Foundation

enum DockExecutionContext: Hashable, Sendable {
    case local
    case remote(DockRemoteExecutionContext)

    var remoteWorkspaceID: UUID? {
        guard case .remote(let context) = self else { return nil }
        return context.workspaceID
    }
}
