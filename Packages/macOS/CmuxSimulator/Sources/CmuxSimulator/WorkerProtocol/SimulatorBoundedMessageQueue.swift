import Foundation

/// A FIFO async queue with an explicit frame-count ceiling.
public struct SimulatorBoundedMessageQueue<Element: Sendable>: Sendable {
    public enum YieldResult: Equatable, Sendable {
        case enqueued
        case overflow
        case terminated
    }

    public let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    public init(limit: Int) {
        (stream, continuation) = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: .bufferingOldest(max(1, limit))
        )
    }

    public func yield(_ element: Element) -> YieldResult {
        switch continuation.yield(element) {
        case .enqueued:
            .enqueued
        case .dropped:
            .overflow
        case .terminated:
            .terminated
        @unknown default:
            .terminated
        }
    }

    public func finish() {
        continuation.finish()
    }
}
