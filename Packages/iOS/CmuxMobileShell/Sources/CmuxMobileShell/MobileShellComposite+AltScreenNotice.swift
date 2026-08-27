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

    /// Returns whether an unknown screen should present the terminal recovery
    /// affordance. Raw-byte-only hosts have no structured screen channel by
    /// design, so they keep their legacy behavior without a misleading alert;
    /// hybrid hosts must resolve the discriminator before suppressing bytes.
    ///
    /// - Parameter surfaceID: The terminal surface identifier to inspect.
    /// - Returns: `true` for an unresolved hybrid screen state.
    public func terminalScreenRecoveryRequired(surfaceID: String) -> Bool {
        terminalOutputTransport == .hybrid
            && terminalActiveScreenState(surfaceID: surfaceID) == .unknown
    }

    /// Returns whether the latest render-grid frame for a surface is alternate screen.
    ///
    /// - Parameter surfaceID: The terminal surface identifier to inspect.
    /// - Returns: `true` when the surface is currently tracked as alternate screen.
    public func isAlternateScreen(surfaceID: String) -> Bool {
        terminalActiveScreenState(surfaceID: surfaceID) == .alternate
    }
}
