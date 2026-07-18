/// Exact acknowledgement that the host no longer reads one renderer surface.
///
/// The worker may reuse the identified IOSurface pool slot only after this
/// acknowledgement arrives through the authenticated control plane. Retaining
/// an IOSurface object protects its lifetime, but does not prevent another
/// process from modifying its pixels.
public struct TerminalRenderFrameRelease: Equatable, Sendable {
    /// Complete frame identity and generation fence being released.
    public let metadata: TerminalRenderFrameMetadata

    /// Kernel IOSurface identifier imported for that exact frame.
    public let surfaceID: UInt32

    /// Creates an immutable pool-release acknowledgement.
    public init(metadata: TerminalRenderFrameMetadata, surfaceID: UInt32) {
        self.metadata = metadata
        self.surfaceID = surfaceID
    }
}
