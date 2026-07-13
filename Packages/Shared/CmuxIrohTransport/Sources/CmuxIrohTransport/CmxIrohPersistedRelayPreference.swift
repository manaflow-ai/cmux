/// Last broker preference and the exact subset safely resolved on this device.
public struct CmxIrohPersistedRelayPreference: Codable, Equatable, Sendable {
    /// Account preference requested by the broker.
    public let requested: CmxIrohAccountRelayPreference

    /// Preference subset that was last safely honored, or `nil` for direct-only.
    public let effective: CmxIrohAccountRelayPreference?

    /// Monotonic broker preference revision.
    public let revision: Int64

    /// Signed policy sequence used to resolve the effective managed selection.
    public let effectivePolicySequence: Int64?

    /// Requested managed IDs missing from that policy.
    public let staleRelayIDs: Set<String>
}
