/// The sudo request lifecycle consumed by the approval coordinator.
public protocol SudoBrokerServing: Sendable {
    /// Returns the authoritative lifecycle event stream.
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
    func approve(id: String) async

    /// Denies the request identified by `id`.
    ///
    /// - Parameter id: The request identifier selected by the user.
    func deny(id: String) async

    /// Stops request observation without abandoning independent runners.
    func stop() async
}

extension SudoBroker: SudoBrokerServing {}
