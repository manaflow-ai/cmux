public import Foundation

/// The resolved set of Vault agent registrations, deduplicated by id.
///
/// Construction collapses duplicate ids keeping the last occurrence at the
/// first id's position, so later config sources override earlier built-in
/// registrations while preserving registration order. This type is the pure
/// value core; config-file discovery and decoding (which depend on the app's
/// `CmuxConfigFile` and JSONC parser) live in an app-side extension so the
/// package stays free of those app types.
public struct CmuxVaultAgentRegistry: Sendable {
    /// The deduplicated, order-preserving registrations.
    public var registrations: [CmuxVaultAgentRegistration]

    /// Creates a registry, deduplicating by id: a later registration with an
    /// id already seen replaces the earlier one in place rather than appending.
    public init(registrations: [CmuxVaultAgentRegistration]) {
        var ordered: [CmuxVaultAgentRegistration] = []
        var indexesByID: [String: Int] = [:]
        for registration in registrations {
            if let existingIndex = indexesByID[registration.id] {
                ordered[existingIndex] = registration
            } else {
                indexesByID[registration.id] = ordered.count
                ordered.append(registration)
            }
        }
        self.registrations = ordered
    }

    /// Returns the registration with the given id, if any.
    public func registration(id: String) -> CmuxVaultAgentRegistration? {
        registrations.first { $0.id == id }
    }
}
