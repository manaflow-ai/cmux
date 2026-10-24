public import Foundation

/// A ``ScrollFrameTiming`` that records nothing: the default of a dispatch context a test or a tool makes.
public struct NoScrollFrameTiming: ScrollFrameTiming {
    /// A timing that records nothing.
    public init() {}

    /// Records nothing.
    ///
    /// - Returns: An end that does nothing.
    public func begin(phase: ScrollFramePhase, eventTimestamp: TimeInterval) -> @MainActor (ScrollFrameTarget) -> Void { { _ in } }
}
