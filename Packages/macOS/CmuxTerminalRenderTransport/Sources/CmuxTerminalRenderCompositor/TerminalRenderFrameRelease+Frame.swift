public import CmuxTerminalRenderProtocol
public import CmuxTerminalRenderTransport

public extension TerminalRenderFrameRelease {
    /// Binds release provenance to the authenticated frame and imported surface.
    init(frame: TerminalRenderFrame) {
        self.init(
            metadata: frame.metadata,
            surfaceID: frame.surface.identifier,
            workerIdentity: frame.workerIdentity
        )
    }
}
