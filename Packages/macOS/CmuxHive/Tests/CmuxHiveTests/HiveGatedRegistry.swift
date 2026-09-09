import CMUXMobileCore
import CmuxMobileShell

/// Holds the first registry response while a second account requests a refresh.
actor HiveGatedRegistry: DeviceRegistryRefreshing {
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var release: CheckedContinuation<Void, Never>?
    private var outcomes: [DeviceRegistryListOutcome]
    private(set) var calls = 0

    init(_ outcomes: [DeviceRegistryListOutcome]) {
        self.outcomes = outcomes
    }

    func freshRoutes(forMacDeviceID macDeviceID: String, instanceTag: String?) async -> [CmxAttachRoute]? {
        nil
    }

    func listDevices() async -> DeviceRegistryListOutcome {
        calls += 1
        let outcome = outcomes.isEmpty ? .transientFailure : outcomes.removeFirst()
        if calls == 1 {
            await withCheckedContinuation { continuation in
                release = continuation
                started.continuation.yield(())
            }
        }
        return outcome
    }

    func releaseFirstResponse() {
        release?.resume()
        release = nil
    }
}
