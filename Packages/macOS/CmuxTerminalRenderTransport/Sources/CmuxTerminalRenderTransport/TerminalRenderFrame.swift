public import CmuxTerminalRenderProtocol

/// An authenticated remote IOSurface and its generation-fenced provenance.
public struct TerminalRenderFrame: Sendable {
    /// Decoded provenance, sequence, format, fence, and damage metadata.
    public let metadata: TerminalRenderFrameMetadata

    /// Retained IOSurface imported only after metadata passed presentation fences.
    public let surface: TerminalRenderSurfaceHandle

    /// Kernel-authenticated renderer process identity.
    public let workerIdentity: TerminalRenderWorkerIdentity

    /// Creates a received frame.
    ///
    /// - Parameters:
    ///   - metadata: Validated frame metadata.
    ///   - surface: Retained imported IOSurface.
    ///   - workerIdentity: PID and UID obtained from the Mach audit trailer.
    public init(
        metadata: TerminalRenderFrameMetadata,
        surface: TerminalRenderSurfaceHandle,
        workerIdentity: TerminalRenderWorkerIdentity
    ) {
        self.metadata = metadata
        self.surface = surface
        self.workerIdentity = workerIdentity
    }
}
