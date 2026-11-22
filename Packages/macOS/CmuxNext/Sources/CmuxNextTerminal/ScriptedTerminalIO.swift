public import Foundation
import Synchronization

/// In-memory ``TerminalIO`` for demos, previews, and tests. Events are pushed
/// with ``send(_:)``; input and resizes Ghostty produces are recorded.
public nonisolated final class ScriptedTerminalIO: TerminalIO {
    public struct Resize: Sendable, Equatable {
        public var columns: Int
        public var rows: Int
        public var pixelWidth: Int
        public var pixelHeight: Int
    }

    public let events: AsyncStream<TerminalIOEvent>
    public let answersTerminalQueries: Bool
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation
    private let recordedWrites = Mutex<[Data]>([])
    private let recordedResizes = Mutex<[Resize]>([])

    public init(answersTerminalQueries: Bool = true) {
        self.answersTerminalQueries = answersTerminalQueries
        // concurrency-allow: scripted demo IO; finite script
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    public func send(_ event: TerminalIOEvent) {
        continuation.yield(event)
    }

    public func finish() {
        continuation.finish()
    }

    public func write(_ data: Data) async {
        recordedWrites.withLock { $0.append(data) }
    }

    public func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        recordedResizes.withLock { $0.append(Resize(columns: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)) }
    }

    /// Input bytes received so far, in order.
    public var writes: [Data] { recordedWrites.withLock { $0 } }
    /// Grid reports received so far, in order.
    public var resizes: [Resize] { recordedResizes.withLock { $0 } }
}
