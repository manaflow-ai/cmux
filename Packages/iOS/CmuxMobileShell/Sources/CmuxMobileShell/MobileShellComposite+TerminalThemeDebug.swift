#if DEBUG
public import CMUXMobileCore

extension MobileShellComposite {
    /// Injects a full render-grid frame through the production surface delivery path.
    ///
    /// UI artifact tests use this to verify mounted Ghostty surfaces, including
    /// ordered theme-config application and terminal canvas repainting through
    /// hybrid delivery, where render-grid frames are advisory for content.
    /// - Parameter frame: The Mac-style terminal frame to deliver.
    /// - Returns: `true` when the target surface has an attached output consumer.
    public func debugDeliverTerminalRenderGrid(_ frame: MobileTerminalRenderGridFrame) -> Bool {
        guard hasTerminalOutputSink(surfaceID: frame.surfaceID) else { return false }
        terminalOutputTransport = .hybrid
        deliverAuthoritativeTerminalRenderGrid(frame, source: "event")
        return true
    }
}
#endif
