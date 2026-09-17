import Foundation

/// Receives bounded terminal input/output timing samples.
///
/// Implementations must keep every method synchronous and non-blocking. The
/// terminal path calls these methods for each input and delivered output, so
/// they may only update bounded in-memory state. Implementations publish
/// periodic aggregates through their existing telemetry queue.
@MainActor
public protocol MobileTerminalLatencyObserving: Sendable {
    func inputStarted(surfaceID: String, byteCount: Int) -> UInt64
    func inputSent(surfaceID: String, sequence: UInt64)
    func inputFailed(surfaceID: String, sequence: UInt64)
    func outputReceived(
        surfaceID: String,
        appliedInputSequence: UInt64?,
        byteCount: Int,
        queueDepth: Int
    )
    func outputPresented(surfaceID: String)
    func outputDropped(surfaceID: String)
    func flush() async
}

public struct NoopMobileTerminalLatencyObserver: MobileTerminalLatencyObserving {
    public init() {}

    public func inputStarted(surfaceID: String, byteCount: Int) -> UInt64 { 0 }
    public func inputSent(surfaceID: String, sequence: UInt64) {}
    public func inputFailed(surfaceID: String, sequence: UInt64) {}
    public func outputReceived(
        surfaceID: String,
        appliedInputSequence: UInt64?,
        byteCount: Int,
        queueDepth: Int
    ) {}
    public func outputPresented(surfaceID: String) {}
    public func outputDropped(surfaceID: String) {}
    public func flush() async {}
}
