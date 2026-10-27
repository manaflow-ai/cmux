import AppKit

extension ContentView {
    /// Clamps the right sidebar to its available and configured width caps.
    ///
    /// The content minimum can exceed either cap in a narrow window, so it is
    /// bounded by the effective maximum before it becomes the lower bound.
    /// `configuredMinimumWidth` lowers the built-in floor when set; it never raises it.
    static func clampedRightSidebarWidth(
        _ candidate: CGFloat,
        availableWidth: CGFloat,
        configuredMaximumWidth: CGFloat? = nil,
        configuredMinimumWidth: CGFloat? = nil,
        contentMinimumWidth: CGFloat = 0
    ) -> CGFloat {
        let floorWidth: CGFloat
        if let configuredMinimumWidth, configuredMinimumWidth.isFinite, configuredMinimumWidth > 0 {
            floorWidth = min(configuredMinimumWidth, minimumRightSidebarWidth)
        } else {
            floorWidth = minimumRightSidebarWidth
        }
        let sanitizedCandidate = candidate.isFinite ? candidate : 220
        let sanitizedAvailableWidth = availableWidth.isFinite && availableWidth > 0 ? availableWidth : 1920
        let availableWidthCap = max(
            floorWidth,
            sanitizedAvailableWidth - minimumTerminalWidthWithRightSidebar
        )
        let configuredOrDefaultCap: CGFloat
        if let configuredMaximumWidth, configuredMaximumWidth.isFinite {
            configuredOrDefaultCap = configuredMaximumWidth
        } else {
            configuredOrDefaultCap = maximumRightSidebarWidth
        }
        let maximumWidth = max(
            floorWidth,
            min(configuredOrDefaultCap, availableWidthCap)
        )
        let contentMinimum = contentMinimumWidth.isFinite ? contentMinimumWidth : floorWidth
        let minimumWidth = min(
            max(floorWidth, contentMinimum),
            maximumWidth
        )
        return max(minimumWidth, min(maximumWidth, sanitizedCandidate))
    }
}
