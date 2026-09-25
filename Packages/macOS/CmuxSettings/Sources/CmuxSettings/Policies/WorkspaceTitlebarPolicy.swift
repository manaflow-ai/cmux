import Foundation

/// Resolves title visibility and window-control space from independent preferences.
public struct WorkspaceTitlebarPolicy: Equatable, Sendable {
    /// The user's title-bar preference, retained while Minimal Mode overrides it.
    public let showTitlebar: Bool

    /// Whether Minimal Mode currently owns the compact window layout.
    public let isMinimalMode: Bool

    /// Whether the workspace title row and its vertical space should be hidden.
    public var isHidden: Bool { isMinimalMode || !showTitlebar }

    /// Creates a policy without reading or changing persisted settings.
    ///
    /// - Parameters:
    ///   - showTitlebar: The independently stored title-bar preference.
    ///   - isMinimalMode: Whether Minimal Mode is active.
    public init(showTitlebar: Bool, isMinimalMode: Bool) {
        self.showTitlebar = showTitlebar
        self.isMinimalMode = isMinimalMode
    }

    /// Returns the tab-strip space reserved for window controls, in points.
    ///
    /// - Parameters:
    ///   - isSidebarVisible: Whether the sidebar already contains the controls.
    ///   - isFullScreen: Whether the window is in native fullscreen.
    ///   - trafficLightInset: The measured inset for native window buttons.
    ///   - fullscreenControlsWidth: The measured width of fullscreen controls.
    /// - Returns: Zero when no inset is needed, otherwise the control width and spacing.
    public func tabBarLeadingInset(
        isSidebarVisible: Bool,
        isFullScreen: Bool,
        trafficLightInset: CGFloat,
        fullscreenControlsWidth: CGFloat
    ) -> CGFloat {
        guard isHidden, !isSidebarVisible else { return 0 }
        if isFullScreen {
            return isMinimalMode ? 0 : fullscreenControlsWidth + 16
        }
        return trafficLightInset
    }
}
