public import CmuxNextSettings

/// One envelope the router sends a page, and what runs if a page reset drops it before the page
/// ran it (a provider replays the event to the page's next document, `AgentPageProvider`).
///
/// ```swift
/// router.send = { deliveries in scripts.send(deliveries) }
/// ```
public struct PageDelivery {
    /// The pane-protocol envelope (`{t: "ev", sub, seq, data}`, a host `call`).
    public let envelope: JSONValue
    /// Runs once when a reset drops the envelope undelivered; nothing for a host call (the router
    /// fails the call itself).
    public let dropped: @MainActor () -> Void

    /// - Parameters:
    ///   - envelope: What the page receives.
    ///   - dropped: Runs if a page reset drops it undelivered (default: nothing).
    public init(_ envelope: JSONValue, dropped: @escaping @MainActor () -> Void = {}) {
        self.envelope = envelope
        self.dropped = dropped
    }
}
