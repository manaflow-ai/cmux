/// The decision produced for one authoritative Ghostty scrollbar packet.
public struct TerminalScrollbackScrollbarSyncDecision: Equatable, Sendable {
    /// The intent to retain after processing the packet.
    public let intent: TerminalScrollbackViewportIntent

    /// Whether the AppKit viewport should be moved to the packet's position.
    public let shouldSynchronizeViewport: Bool

    /// Whether this packet consumed a pending explicit user-scroll request.
    public let consumedExplicitSync: Bool

    /// Creates a packet synchronization decision.
    ///
    /// - Parameters:
    ///   - intent: The intent to retain after processing the packet.
    ///   - shouldSynchronizeViewport: Whether AppKit should adopt the packet's viewport.
    ///   - consumedExplicitSync: Whether the packet resolved an explicit request.
    public init(
        intent: TerminalScrollbackViewportIntent,
        shouldSynchronizeViewport: Bool,
        consumedExplicitSync: Bool
    ) {
        self.intent = intent
        self.shouldSynchronizeViewport = shouldSynchronizeViewport
        self.consumedExplicitSync = consumedExplicitSync
    }
}
