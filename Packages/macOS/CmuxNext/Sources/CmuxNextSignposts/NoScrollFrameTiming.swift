public import Foundation

/// A ``ScrollFrameTiming`` that records nothing: the default of a dispatch context a test or a tool makes.
public struct NoScrollFrameTiming: ScrollFrameTiming {
    /// A timing that records nothing.
    public init() {}

    /// Records nothing.
    public func begin(phase: ScrollFramePhase, eventTimestamp: TimeInterval) {}

    /// Records nothing.
    public func end(target: ScrollFrameTarget) {}
}
