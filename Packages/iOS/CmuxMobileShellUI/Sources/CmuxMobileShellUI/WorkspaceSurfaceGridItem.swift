import CmuxMobileShellModel

/// Immutable card data for one terminal or browser in the workspace grid.
struct WorkspaceSurfaceGridItem: Identifiable, Equatable {
    let id: String
    let workspaceID: MobileWorkspacePreview.ID
    let kind: WorkspaceSurfaceGridItemKind
    let title: String
    let subtitle: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
    let isDimmed: Bool
    let canClose: Bool
}
