public import Foundation

/// Exact Ghostty frame ownership retained until the host GPU copy completes.
public struct RendererFrameLease: Equatable, Sendable {
    public let rendererEpoch: UInt64
    public let terminalID: UUID
    public let terminalEpoch: UInt64
    public let terminalSequence: UInt64
    public let presentationID: UUID
    public let presentationGeneration: UInt64
    public let presentationSequence: UInt64
    public let frameSequence: UInt64
    public let surfaceID: UInt32
    public let width: UInt32
    public let height: UInt32

    public init(
        rendererEpoch: UInt64,
        terminalID: UUID,
        terminalEpoch: UInt64,
        terminalSequence: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        presentationSequence: UInt64,
        frameSequence: UInt64,
        surfaceID: UInt32,
        width: UInt32,
        height: UInt32
    ) {
        self.rendererEpoch = rendererEpoch
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.terminalSequence = terminalSequence
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.presentationSequence = presentationSequence
        self.frameSequence = frameSequence
        self.surfaceID = surfaceID
        self.width = width
        self.height = height
    }
}
