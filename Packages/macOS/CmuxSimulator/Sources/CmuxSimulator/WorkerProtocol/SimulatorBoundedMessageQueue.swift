import Foundation

/// A FIFO async queue with an explicit frame-count ceiling.
public struct SimulatorBoundedMessageQueue<Element: Sendable>: Sendable {
    /// Values yielded by the queue's bounded stream.
    public let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    /// Creates a queue whose oldest buffered element is retained on overflow.
    /// - Parameter limit: Maximum number of buffered elements.
    public init(limit: Int) {
        (stream, continuation) = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: .bufferingOldest(max(1, limit))
        )
    }

    /// Attempts to enqueue an element without exceeding the fixed buffer.
    /// - Parameter element: Element to deliver to the ordered consumer.
    /// - Returns: Whether the element was enqueued, overflowed, or arrived after termination.
    public func yield(_ element: Element) -> SimulatorBoundedMessageQueueYieldResult {
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

    /// Finishes the queue and its stream.
    public func finish() {
        continuation.finish()
    }
}
