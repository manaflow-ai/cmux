/// Two-axis occlusion state for a terminal surface.
///
/// Ghostty should render only when the surface is both visible in the UI
/// (portal/canvas visibility) and its host window is visible according to
/// `NSWindow.occlusionState`.
public struct SurfaceOcclusionState: Equatable, Sendable {
    /// Whether the portal or canvas currently considers the surface visible.
    public var uiVisible: Bool

    /// Whether the host window is currently visible to AppKit.
    public var windowVisible: Bool

    /// Creates occlusion state with both axes visible by default.
    ///
    /// - Parameters:
    ///   - uiVisible: The current portal or canvas visibility.
    ///   - windowVisible: The current host-window visibility.
    public init(uiVisible: Bool = true, windowVisible: Bool = true) {
        self.uiVisible = uiVisible
        self.windowVisible = windowVisible
    }

    /// Whether Ghostty should treat the surface as visible.
    public var effectiveVisible: Bool {
        uiVisible && windowVisible
    }
}
