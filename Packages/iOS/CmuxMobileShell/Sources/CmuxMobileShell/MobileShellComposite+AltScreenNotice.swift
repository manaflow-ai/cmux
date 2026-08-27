public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Returns the tri-state screen information for a terminal surface.
    ///
    /// - Parameter surfaceID: The terminal surface identifier to inspect.
    /// - Returns: The latest authoritative screen, or ``MobileTerminalActiveScreenState/unknown``
    ///   while compatibility output lacks a screen discriminator.
    public func terminalActiveScreenState(
        surfaceID: String
    ) -> MobileTerminalActiveScreenState {
        if terminalActiveScreenUnknownSurfaceIDs.contains(surfaceID) {
            return .unknown
        }
        guard let activeScreen = terminalActiveScreenBySurfaceID[surfaceID] else {
            return .unknown
        }
        return activeScreen == .alternate ? .alternate : .primary
    }

    /// Returns whether the latest render-grid frame for a surface is alternate screen.
    ///
    /// - Parameter surfaceID: The terminal surface identifier to inspect.
    /// - Returns: `true` when the surface is currently tracked as alternate screen.
    public func isAlternateScreen(surfaceID: String) -> Bool {
        terminalActiveScreenState(surfaceID: surfaceID) == .alternate
    }
}
