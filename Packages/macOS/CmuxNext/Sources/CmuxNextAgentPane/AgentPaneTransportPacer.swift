public import Foundation

/// What one flush did: whether it made a bridge call (``AgentPaneTransportPacer/delivered()``
/// follows when the page has run it) and whether frames are still waiting.
public nonisolated struct AgentPaneFlush: Equatable, Sendable {
    public var delivered: Bool
    public var more: Bool
    public init(delivered: Bool, more: Bool) {
        self.delivered = delivered
        self.more = more
    }
}

/// When the transport delivers what arrived. Production delivers at once when idle and coalesces
/// only under load (``AgentPaneFramePacer``); tests flush on the next main-loop turn or by hand.
@MainActor public protocol AgentPaneTransportPacer: AnyObject {
    /// Frames arrived: arrange for `flush` to run, and again while it reports more waiting.
    func schedule(_ flush: @escaping @MainActor @Sendable () -> AgentPaneFlush)
    /// The page has run the last call `flush` made.
    func delivered()
    /// The connection changed or closed: forget what was in flight.
    func reset()
}

public extension AgentPaneTransportPacer {
    func delivered() {}
    func reset() {}
}

/// Flushes on the next main-loop turn, again while more is waiting.
@MainActor public final class AgentPaneNextTurnPacer: AgentPaneTransportPacer {
    private var scheduled = false
    public init() {}

    public func schedule(_ flush: @escaping @MainActor @Sendable () -> AgentPaneFlush) {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                if flush().more { self?.schedule(flush) }
            }
        }
    }
}
