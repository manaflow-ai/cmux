/// The coalescing seam for high-frequency scrollbar updates posted by the
/// terminal runtime.
///
/// The Ghostty action callback fires on the runtime's I/O thread, potentially
/// thousands of times per second during bulk output (e.g. `seq 1 100000`). The
/// legacy `GhosttyNSView` coalesced these with an `NSLock`-guarded pending value
/// plus a single `DispatchQueue.main.async` flush. This seam replaces that lock
/// + dispatch pair: the producer offers each value into a buffering
/// ``AsyncStream`` (newest-wins), and a single consumer task on the main actor
/// drains it, so only the latest value reaches the surface even under bursts.
///
/// ## Isolation design
///
/// The continuation is `Sendable`, so the off-main producer (the runtime
/// callback) may yield without hopping to the main actor. The consumer side is
/// driven by ``TerminalSurfaceRenderCoordinator`` on the main actor, which is
/// where the surface state it mutates lives. `bufferingNewest(1)` reproduces the
/// "always overwrites, only the newest matters" coalescing of the legacy lock.
public protocol TerminalScrollbarObserving: Sendable {
    /// Offers the latest scrollbar snapshot for coalesced delivery.
    ///
    /// Safe to call from any thread, including the runtime I/O thread. Only the
    /// newest value survives if the consumer has not yet drained.
    ///
    /// - Parameter scrollbar: The latest scrollback geometry snapshot.
    func offer(_ scrollbar: GhosttyScrollbar)

    /// The coalesced stream of scrollbar snapshots, newest-wins buffered.
    var snapshots: AsyncStream<GhosttyScrollbar> { get }
}

/// The default newest-wins coalescing implementation of ``TerminalScrollbarObserving``.
///
/// Holds only the stream continuation; all surface mutation happens in the
/// consumer (``TerminalSurfaceRenderCoordinator``). The buffering policy is the
/// faithful replacement for the legacy `_pendingScrollbar` + `_scrollbarLock` +
/// `_scrollbarFlushScheduled` trio.
public struct TerminalScrollbarObserver: TerminalScrollbarObserving {
    public let snapshots: AsyncStream<GhosttyScrollbar>
    private let continuation: AsyncStream<GhosttyScrollbar>.Continuation

    /// Creates a coalescing observer with a single-slot newest-wins buffer.
    public init() {
        var continuation: AsyncStream<GhosttyScrollbar>.Continuation!
        snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.continuation = continuation
    }

    public func offer(_ scrollbar: GhosttyScrollbar) {
        continuation.yield(scrollbar)
    }
}
