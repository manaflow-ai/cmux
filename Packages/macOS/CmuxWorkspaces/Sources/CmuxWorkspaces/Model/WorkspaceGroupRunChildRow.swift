import Foundation

/// One renderable child of a workspace-group run: either a nested group (shown
/// at its anchor's position) or a loose member workspace. Built and consumed
/// only inside `@MainActor` `WorkspacesModel` normalization, and it carries a
/// live `Tab` reference whose identity/pin state are `@MainActor`-isolated, so
/// the type is main-actor isolated to match.
@MainActor
enum WorkspaceGroupRunChildRow<Tab: WorkspaceTabRepresenting> {
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
