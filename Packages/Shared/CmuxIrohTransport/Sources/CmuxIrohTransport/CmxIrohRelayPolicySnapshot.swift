/// One verified managed policy with its resolved device-local relay selection.
public struct CmxIrohRelayPolicySnapshot: Equatable, Sendable {
    /// The signed policy that authorizes every selected relay URL.
    public let policy: CmxIrohManagedRelayPolicy

    /// The device-local selection used to derive ``relays``.
    public let selection: CmxIrohManagedRelaySelection

    /// The selected relays in signed policy order.
    public let relays: [CmxIrohManagedRelayDescriptor]

    /// Exact selected relay origins accepted by runtime and cache validation.
    public var relayURLs: Set<String> {
        Set(relays.map(\.url))
    }

    /// Resolves a local selection against a verified policy.
    ///
    /// - Parameters:
    ///   - policy: A policy returned by ``CmxIrohRelayPolicyVerifier``.
    ///   - selection: The device-local managed-relay selection.
    /// - Throws: ``CmxIrohRelayPolicyError/invalidSelection`` for stale selection.
    public init(
        policy: CmxIrohManagedRelayPolicy,
        selection: CmxIrohManagedRelaySelection
    ) throws {
        self.policy = policy
        self.selection = selection
        relays = try selection.resolve(in: policy)
    }
}
