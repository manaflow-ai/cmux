#if DEBUG
public import CMUXMobileCore

extension MobileShellComposite {
    /// Injects a render-grid frame through the production surface delivery path.
    ///
    /// The theme-parity UI fixture uses this to verify mounted Ghostty surfaces,
    /// ordered config application, and canvas repainting through hybrid delivery.
    /// - Parameter frame: The Mac-style terminal frame to deliver.
    /// - Returns: `true` when the target surface has an attached output consumer.
    public func deliverThemeParityPreviewFrame(_ frame: MobileTerminalRenderGridFrame) -> Bool {
        guard hasTerminalOutputSink(surfaceID: frame.surfaceID) else { return false }
        terminalOutputTransport = .hybrid
        deliverAuthoritativeTerminalRenderGrid(frame, source: "event")
        return true
    }
}
#endif
