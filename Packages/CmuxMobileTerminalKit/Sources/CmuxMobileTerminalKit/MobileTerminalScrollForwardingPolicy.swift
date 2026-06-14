public import CMUXMobileCore

/// Decides whether a mobile terminal scroll gesture must be sent to the Mac.
public struct MobileTerminalScrollForwardingPolicy: Sendable {
    /// Creates the forwarding policy.
    public init() {}

    /// Returns whether a scroll should be forwarded to the host surface.
    ///
    /// Primary-screen scrollback is already mirrored into the phone's local
    /// Ghostty surface, so forwarding would make scroll feel network-bound.
    /// Alternate-screen scroll must still reach the host so TUIs with mouse
    /// reporting receive wheel events.
    /// - Parameter activeScreen: The screen currently rendered by the mobile
    ///   Ghostty mirror.
    /// - Returns: `true` when the scroll should be sent to the Mac.
    public func shouldForwardToHost(
        activeScreen: MobileTerminalRenderGridFrame.Screen
    ) -> Bool {
        activeScreen == .alternate
    }
}
