import CMUXMobileCore
import CmuxMobileShell

/// Registry fake that returns scripted outcomes in order.
actor SequencedRegistry: DeviceRegistryRefreshing {
    private var outcomes: [DeviceRegistryListOutcome]

    init(_ outcomes: [DeviceRegistryListOutcome]) {
        self.outcomes = outcomes
    }

    func freshRoutes(forMacDeviceID macDeviceID: String, instanceTag: String?) async -> [CmxAttachRoute]? {
        nil
    }

    func listDevices() async -> DeviceRegistryListOutcome {
        guard outcomes.count > 1 else { return outcomes.first ?? .transientFailure }
        return outcomes.removeFirst()
    }
}
