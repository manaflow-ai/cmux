/// A user's selection within the currently signed managed-relay catalog.
public enum CmxIrohManagedRelaySelection: Equatable, Sendable {
    /// Allow every compatible relay and let Iroh choose the closest home relay.
    case automatic

    /// Allow only the selected stable relay identifiers.
    case only(Set<String>)

    /// Resolves this selection against one verified policy.
    ///
    /// - Parameter policy: The verified managed-relay catalog.
    /// - Returns: Relays in signed policy order, filtered by the local selection.
    /// - Throws: ``CmxIrohRelayPolicyError/invalidSelection`` for stale or empty IDs.
    public func resolve(
        in policy: CmxIrohManagedRelayPolicy
    ) throws -> [CmxIrohManagedRelayDescriptor] {
        switch self {
        case .automatic:
            return policy.relays
        case let .only(ids):
            guard !ids.isEmpty,
                  ids.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount else {
                throw CmxIrohRelayPolicyError.invalidSelection
            }
            let resolved = policy.relays.filter { ids.contains($0.id) }
            guard resolved.count == ids.count else {
                throw CmxIrohRelayPolicyError.invalidSelection
            }
            return resolved
        }
    }
}
