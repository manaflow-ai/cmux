import Foundation

/// One namespace for a Simulator resource that must not be mutated concurrently.
package struct SimulatorMutationKey: Hashable, Sendable {
    package let value: String

    private init(_ value: String) {
        self.value = value
    }

    /// Serializes TCC database changes for one simulated device.
    package static func tcc(deviceIdentifier: String) -> Self {
        Self("tcc\0\(normalized(deviceIdentifier))")
    }

    /// Serializes launch, termination, camera injection, and inspection for one app.
    package static func application(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) -> Self {
        Self(
            "application\0\(normalized(deviceIdentifier))\0\(normalized(bundleIdentifier))"
        )
    }

    /// Serializes updates to one persistent per-device Simulator data store.
    package static func store(deviceIdentifier: String, name: String) -> Self {
        Self("store\0\(normalized(deviceIdentifier))\0\(normalized(name))")
    }

    /// Serializes private interface-setting writes for one simulated device.
    package static func interface(deviceIdentifier: String) -> Self {
        Self("interface\0\(normalized(deviceIdentifier))")
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }
}
