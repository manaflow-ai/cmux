import CmuxMobileShellModel

/// Immutable card data for one terminal or browser in the workspace grid.
struct WorkspaceSurfaceGridItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case terminal(MobileTerminalPreview.ID)
        case browser
    }

    let id: String
    let workspaceID: MobileWorkspacePreview.ID
    let kind: Kind
    let title: String
    let subtitle: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
    let isDimmed: Bool
    let canClose: Bool
}
