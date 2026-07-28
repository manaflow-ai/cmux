import Foundation

nonisolated enum CmuxConfigActionCatalogDirectorySource: Hashable, Sendable {
    case global
    case workspace(UUID)
    case panel(workspaceID: UUID, panelID: UUID)

    var workspaceID: UUID? {
        switch self {
        case .global:
            nil
        case .workspace(let workspaceID), .panel(let workspaceID, _):
            workspaceID
        }
    }
}
