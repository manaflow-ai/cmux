import Foundation

enum WorkspaceGroupRunChildRow {
    case group(WorkspaceGroup)
    case workspace(Tab)

    var workspaceId: UUID {
        switch self {
        case .group(let group):
            return group.anchorWorkspaceId
        case .workspace(let tab):
            return tab.id
        }
    }

    var isPinned: Bool {
        switch self {
        case .group(let group):
            return group.isPinned
        case .workspace(let tab):
            return tab.isPinned
        }
    }
}
