/// Launches the standalone SSH process that owns one reverse relay.
public protocol RemoteReverseRelayLaunching: Sendable {
    /// Starts `/usr/bin/ssh` with the supplied dedicated-relay configuration.
    ///
    /// - Parameters:
    ///   - arguments: SSH arguments for the reverse-relay transport.
    ///   - environment: Process environment, or `nil` to inherit.
    ///   - terminationHandler: Called when the launched transport exits.
    /// - Returns: A coordinator-owned handle for the running transport.
    /// - Throws: A Foundation process-launch error.
    func launch(
        arguments: [String],
        environment: [String: String]?,
        terminationHandler: @escaping @Sendable (any RemoteReverseRelayProcess) -> Void
    ) throws -> any RemoteReverseRelayProcess
}
