/// The resolved visibility/opacity a mounted workspace should present with.
/// Pure value type holding no state and touching no UI.
public struct MountedWorkspacePresentation: Equatable {
    public let isRenderedVisible: Bool
    public let isPanelVisible: Bool
    public let renderOpacity: Double

    public init(
        isRenderedVisible: Bool,
        isPanelVisible: Bool,
        renderOpacity: Double
    ) {
        self.isRenderedVisible = isRenderedVisible
        self.isPanelVisible = isPanelVisible
        self.renderOpacity = renderOpacity
    }

    /// Resolves how a mounted workspace should present based on whether it is the
    /// selected or retiring workspace.
    public static func resolve(
        isSelectedWorkspace: Bool,
        isRetiringWorkspace: Bool
    ) -> MountedWorkspacePresentation {
        let isRenderedVisible = isSelectedWorkspace || isRetiringWorkspace

        return MountedWorkspacePresentation(
            isRenderedVisible: isRenderedVisible,
            isPanelVisible: isRenderedVisible,
            renderOpacity: isRenderedVisible ? 1 : 0
        )
    }
}
