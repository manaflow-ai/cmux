/// The WireGuard callback boundary consumed by the ordered provider lifecycle.
///
/// These callback methods deliberately return before the operation completes:
/// the owner must keep accepting NetworkExtension stop requests while startup
/// is in flight. Completions enqueue events back into its single AsyncStream.
public protocol CloudTunnelAdapter: Sendable {
    /// Starts the adapter with a complete saved configuration.
    /// - Parameters:
    ///   - configuration: Key-bearing configuration; must never be logged.
    ///   - completion: Reports the actual startup result.
    func start(configuration: String, completion: @escaping CloudTunnelProviderStartGate.Completion)

    /// Stops the adapter and completes only after teardown finishes.
    /// - Parameter completion: Signals that resources have been released.
    func stop(completion: @escaping CloudTunnelProviderStartGate.StopCompletion)
}
