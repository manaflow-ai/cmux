/// The sudo request lifecycle consumed by the approval coordinator.
public protocol SudoBrokerServing: Sendable {
    /// Returns the authoritative lifecycle event stream.
    ///
    /// Call once for the broker's single presentation consumer; the returned
    /// bounded stream is not a broadcast bus for independent consumers.
    ///
    /// - Returns: A bounded stream of request lifecycle changes.
    func events() async -> AsyncStream<SudoBrokerEvent>

    /// Creates and reconciles the private spool, then begins watching it.
    ///
    /// - Returns: Every active request snapshot after startup reconciliation.
    /// - Throws: A spool or observation error that prevents safe startup.
    func start() async throws -> [SudoPendingRequest]

    /// Approves the exact script captured for `id`.
    ///
    /// - Parameter id: The request identifier selected by the user.
    /// - Returns: Whether the request left the pending phase.
    @discardableResult
    func approve(id: String) async -> SudoDecisionOutcome

    /// Denies the request identified by `id`.
    ///
    /// - Parameter id: The request identifier selected by the user.
    /// - Returns: Whether the request left the pending phase.
    @discardableResult
    func deny(id: String) async -> SudoDecisionOutcome

    /// Stops request observation without abandoning independent runners.
    func stop() async
}

extension SudoBroker: SudoBrokerServing {}
