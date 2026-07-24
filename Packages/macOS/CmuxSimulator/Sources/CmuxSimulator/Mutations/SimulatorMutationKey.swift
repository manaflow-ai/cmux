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
    /// Factory for attached Web Inspector target leases.
    package static let webInspector = SimulatorMutationKeyFactory(namespace: "web-inspector")
    /// Factory for the device-wide lifecycle exclusion key.
    package static let device = SimulatorMutationKeyFactory(namespace: "device")

    /// Canonical value used for ordering and lock-file identity.
    package let value: String

    /// Creates a key from an already canonical resource value.
    package init(value: String) {
        self.value = value
    }

    package var deviceScope: SimulatorMutationKey? {
        let components = value.split(separator: "\0", omittingEmptySubsequences: false)
        guard components.count >= 2, components[0] != "device",
              components[0] != "web-inspector" else { return nil }
        return .device(deviceIdentifier: String(components[1]))
    }
}
