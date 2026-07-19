import CmuxFoundation

/// A synchronous, thread-safe invalidation signal for a terminal output callback.
///
/// The raw callback only advances an atomic revision and yields into a
/// buffering-newest stream. It never captures a screen, classifies text, or
/// creates a task.
public final class AgentTerminalDirtySignal: Sendable {
    private let generation = AtomicUInt64Generation()
    private let continuation: AsyncStream<UInt64>.Continuation

    /// The single-consumer stream of coalesced newest revisions.
    public let revisions: AsyncStream<UInt64>

    /// Creates an initially clean signal.
    public init() {
        let pair = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        revisions = pair.stream
        continuation = pair.continuation
    }

    deinit {
        continuation.finish()
    }

    /// Marks newer terminal evidence from a synchronous PTY callback.
    @inline(__always)
    public func markDirty() {
        continuation.yield(generation.advanceRelaxed())
    }

    /// Returns the newest invalidation revision without an actor hop.
    @inline(__always)
    public func currentRevision() -> UInt64 {
        generation.loadRelaxed()
    }
}
