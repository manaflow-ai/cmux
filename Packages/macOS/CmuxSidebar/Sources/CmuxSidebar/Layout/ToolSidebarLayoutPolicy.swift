public import CoreGraphics
public import CmuxSettings

/// Resolves where the native tool sidebar appears relative to workspace content.
public struct ToolSidebarLayoutPolicy: Sendable {
    /// Creates a tool-sidebar layout policy.
    public init() {}

    /// Returns whether the tool sidebar belongs before the workspace content.
    ///
    /// - Parameter position: The configured horizontal edge for the tool sidebar.
    /// - Returns: `true` when the tool sidebar should be the leading layout child.
    public func placesToolSidebarBeforeWorkspace(for position: ToolSidebarPosition) -> Bool {
        position == .left
    }
}

/// Resolves leading mode-bar padding when native window controls share the tool sidebar edge.
public struct ToolSidebarModeBarLayoutPolicy: Sendable {
    /// The compact leading padding used when window controls cannot overlap the mode bar.
    public let defaultLeadingPadding: CGFloat

    /// The spacing retained after fullscreen controls.
    public let fullscreenControlClearance: CGFloat

    /// Creates a mode-bar layout policy.
    ///
    /// - Parameters:
    ///   - defaultLeadingPadding: Compact padding used for right placement or a visible workspace sidebar.
    ///   - fullscreenControlClearance: Extra spacing retained after fullscreen controls.
    public init(
        defaultLeadingPadding: CGFloat = 4,
        fullscreenControlClearance: CGFloat = 8
    ) {
        self.defaultLeadingPadding = defaultLeadingPadding
        self.fullscreenControlClearance = fullscreenControlClearance
    }

    /// Returns the leading padding needed to keep mode buttons clear of window controls.
    ///
    /// - Parameters:
    ///   - position: The configured horizontal edge for the tool sidebar.
    ///   - isWorkspaceSidebarVisible: Whether the workspace sidebar already separates the mode bar from leading controls.
    ///   - isFullScreen: Whether cmux is presenting its own fullscreen controls.
    ///   - trafficLightInset: The leading inset occupied by standard macOS traffic lights.
    ///   - fullscreenControlsLeadingPadding: The leading origin of cmux fullscreen controls.
    ///   - fullscreenControlsWidth: The current width of cmux fullscreen controls.
    /// - Returns: The mode bar's required leading padding.
    public func leadingPadding(
        position: ToolSidebarPosition,
        isWorkspaceSidebarVisible: Bool,
        isFullScreen: Bool,
        trafficLightInset: CGFloat,
        fullscreenControlsLeadingPadding: CGFloat,
        fullscreenControlsWidth: CGFloat
    ) -> CGFloat {
        guard position == .left, !isWorkspaceSidebarVisible else {
            return defaultLeadingPadding
        }

        if isFullScreen {
            return max(
                defaultLeadingPadding,
                fullscreenControlsLeadingPadding + fullscreenControlsWidth + fullscreenControlClearance
            )
        }

        return max(defaultLeadingPadding, trafficLightInset)
    }
}
