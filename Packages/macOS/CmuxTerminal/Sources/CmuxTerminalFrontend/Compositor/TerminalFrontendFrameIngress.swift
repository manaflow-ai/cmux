public import CmuxTerminalRenderCompositor
public import CmuxTerminalRenderTransport

/// Sendable frame-admission seam exposed by the lightweight Swift frontend.
public protocol TerminalFrontendFrameIngress: Sendable {
    /// Admits one authenticated IOSurface frame for the current presentation.
    ///
    /// - Parameter frame: The received frame and exact provenance metadata.
    /// - Returns: The compositor admission or submission result.
    func enqueue(
        _ frame: TerminalRenderFrame
    ) async -> TerminalRenderCompositorEnqueueResult
}
