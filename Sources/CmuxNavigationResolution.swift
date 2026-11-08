import Foundation

/// A resolved navigation target, expressed in current-session identifiers.
enum CmuxNavigationResolution: Equatable {
    case workspace(workspaceId: UUID)
    case pane(workspaceId: UUID, paneId: UUID)
    case surface(workspaceId: UUID, panelId: UUID)

    var workspaceId: UUID {
        switch self {
        case .workspace(let workspaceId),
             .pane(let workspaceId, _),
             .surface(let workspaceId, _):
            return workspaceId
        }
    }
}
