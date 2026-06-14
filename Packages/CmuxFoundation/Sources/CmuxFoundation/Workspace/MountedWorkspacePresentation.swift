/// The resolved visibility/opacity a mounted workspace should present with.
/// Pure value type; computed by `MountedWorkspacePresentationPolicy`.
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
}
