/// Environment captured with one hook admission.
///
/// Durable values are safe to persist for crash recovery. Credential-bearing
/// values exist only in memory for retries in the current app process.
public struct AgentHookTransportEnvironment: Sendable, Equatable {
    /// Values safe to write to the durable delivery queue.
    public let durable: [String: String]

    /// Values retained only in the current app process.
    public let ephemeral: [String: String]

    /// Creates a partitioned hook environment.
    ///
    /// - Parameters:
    ///   - durable: Values safe for durable storage.
    ///   - ephemeral: Memory-only values that override durable values during live delivery.
    public init(durable: [String: String], ephemeral: [String: String]) {
        self.durable = durable
        self.ephemeral = ephemeral
    }

    /// The environment delivered in the current process, with memory-only values taking precedence.
    public var merged: [String: String] {
        durable.merging(ephemeral, uniquingKeysWith: { _, ephemeralValue in ephemeralValue })
    }
}
