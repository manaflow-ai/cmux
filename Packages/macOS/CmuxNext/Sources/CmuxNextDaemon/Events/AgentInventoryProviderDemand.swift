import Foundation

/// Permissioned demand for cache invalidations on one registered provider transport.
public nonisolated struct AgentInventoryProviderDemand: Codable, Sendable, Equatable {
    /// Exact native demand generation; never represented as a floating point number.
    public let sequence: UInt64
    /// Whether a currently readable app subscription needs invalidations.
    public let enabled: Bool

    /// Creates a demand snapshot without granting permission to any machine.
    /// - Parameters:
    ///   - sequence: The native provider generation.
    ///   - enabled: Whether native subscribers currently need invalidations.
    public init(sequence: UInt64, enabled: Bool) { self.sequence = sequence; self.enabled = enabled }

    /// Reads a normalized side event. Match its envelope's source before using it.
    /// - Parameter event: An event from the provider's captured control transport.
    public init?(_ event: DaemonEvent) {
        guard case .unknown("apps-agent-inventory-demand", let payload) = event,
              let decimal = payload["sequence"]?.stringValue, let sequence = UInt64(decimal),
              let enabled = payload["enabled"]?.boolValue else { return nil }
        self.init(sequence: sequence, enabled: enabled)
    }

    static func payload(line: Data, decoder: WireDecoder = WireCoding.decoder()) -> JSONValue {
        guard let demand = try? decoder.decode(Self.self, from: line) else { return .null }
        return .object(["sequence": .string(String(demand.sequence)), "enabled": .bool(demand.enabled)])
    }
}
