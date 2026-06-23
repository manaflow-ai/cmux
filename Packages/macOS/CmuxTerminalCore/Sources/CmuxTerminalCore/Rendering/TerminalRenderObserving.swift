/// The coalescing seam for "a frame was rendered" wakeups posted by the
/// terminal runtime.
///
/// The legacy `GhosttyNSView` coalesced rendered-frame notifications with an
/// `NSLock`-guarded `_renderedFrameFlushScheduled` flag plus a single
/// `DispatchQueue.main.async` flush, gated on
/// `GhosttyApp.renderedFrameNotificationDemand`. This seam replaces the lock +
/// dispatch pair: the producer offers a tick into a buffering ``AsyncStream``
/// (newest-wins), and a single consumer task on the main actor drains it and
/// posts the rendered-frame notification, so a burst of frame wakeups collapses
/// to one main-actor delivery.
///
/// ## Isolation design
///
/// Unlike ``TerminalScrollbarObserving`` there is no value payload; a render
/// tick is a bare signal. The demand gate (only deliver when some consumer has
/// retained frame notifications) is evaluated by the producer before offering
/// and re-checked by the consumer before posting, exactly matching the legacy
/// `isActive` checks at both `enqueue` and `flush` time.
public protocol TerminalRenderObserving: Sendable {
    /// Offers a render tick for coalesced delivery.
    ///
    /// Safe to call from any thread. Collapses to a single main-actor delivery
    /// if the consumer has not yet drained.
    func offer()

    /// The coalesced stream of render ticks, newest-wins buffered.
    var ticks: AsyncStream<Void> { get }
}

/// The default newest-wins coalescing implementation of ``TerminalRenderObserving``.
///
/// Holds only the stream continuation. The faithful replacement for the legacy
/// `_renderedFrameFlushScheduled` + `_renderedFrameLock` pair.
public struct TerminalRenderObserver: TerminalRenderObserving {
    public let ticks: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    /// Creates a coalescing observer with a single-slot newest-wins buffer.
    public init() {
        var continuation: AsyncStream<Void>.Continuation!
        ticks = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.continuation = continuation
    }

    public func offer() {
        continuation.yield(())
    }
}
