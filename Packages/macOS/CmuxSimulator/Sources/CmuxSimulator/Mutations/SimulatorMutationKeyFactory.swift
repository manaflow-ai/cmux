import Foundation

/// Constructs deterministic mutation keys for one resource namespace.
package struct SimulatorMutationKeyFactory: Sendable {
    private let namespace: String

    /// Creates a factory for one mutation-resource namespace.
    package init(namespace: String) {
        self.namespace = namespace
    }

    /// Creates a device-scoped mutation key.
    package func callAsFunction(deviceIdentifier: String) -> SimulatorMutationKey {
        SimulatorMutationKey(
            value: "\(namespace)\0\(normalizedSimulatorMutationComponent(deviceIdentifier))"
        )
    }

    /// Creates an application-scoped mutation key.
    package func callAsFunction(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) -> SimulatorMutationKey {
        SimulatorMutationKey(
            value: "\(namespace)\0\(normalizedSimulatorMutationComponent(deviceIdentifier))"
                + "\0\(normalizedSimulatorMutationComponent(bundleIdentifier))"
        )
    }

    /// Creates a named persistent-store mutation key.
    package func callAsFunction(
        deviceIdentifier: String,
        name: String
    ) -> SimulatorMutationKey {
        SimulatorMutationKey(
            value: "\(namespace)\0\(normalizedSimulatorMutationComponent(deviceIdentifier))"
                + "\0\(normalizedSimulatorMutationComponent(name))"
        )
    }
}

private func normalizedSimulatorMutationComponent(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.lowercased()
}
