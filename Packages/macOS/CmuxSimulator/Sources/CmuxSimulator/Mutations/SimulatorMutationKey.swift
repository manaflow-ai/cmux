import Foundation

/// One Simulator resource that must not be mutated concurrently.
package struct SimulatorMutationKey: Hashable, Sendable {
    /// Factory for TCC database mutation keys.
    package static let tcc = SimulatorMutationKeyFactory(namespace: "tcc")
    /// Factory for application lifecycle mutation keys.
    package static let application = SimulatorMutationKeyFactory(namespace: "application")
    /// Factory for persistent store mutation keys.
    package static let store = SimulatorMutationKeyFactory(namespace: "store")
    /// Factory for private interface mutation keys.
    package static let interface = SimulatorMutationKeyFactory(namespace: "interface")
    /// Factory for simulated-location mutation keys.
    package static let location = SimulatorMutationKeyFactory(namespace: "location")

    /// Canonical value used for ordering and lock-file identity.
    package let value: String

    /// Creates a key from an already canonical resource value.
    package init(value: String) {
        self.value = value
    }
}
