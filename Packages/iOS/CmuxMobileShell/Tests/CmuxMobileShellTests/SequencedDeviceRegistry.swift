import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel

/// Fixture-only registry that lets stale-load tests control response order.
actor SequencedDeviceRegistry: DeviceRegistryRefreshing {
    private let outcomes: [DeviceRegistryListOutcome]
    private var callCount = 0
    private var callWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var firstCallGate: CheckedContinuation<Void, Never>?

    init(outcomes: [DeviceRegistryListOutcome]) {
        self.outcomes = outcomes
    }

    func freshRoutes(
        forMacDeviceID _: String,
        instanceTag _: String?
    ) async -> [CmxAttachRoute]? { nil }

    func listDevices() async -> DeviceRegistryListOutcome {
        callCount += 1
        let call = callCount
        let waiters = callWaiters.removeValue(forKey: call) ?? []
        for waiter in waiters { waiter.resume() }
        if call == 1 {
            await withCheckedContinuation { continuation in
                firstCallGate = continuation
            }
        }
        return outcomes[min(call - 1, outcomes.count - 1)]
    }

    func waitUntilCall(_ expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { continuation in
            callWaiters[expected, default: []].append(continuation)
        }
    }

    func releaseFirstCall() {
        firstCallGate?.resume()
        firstCallGate = nil
    }
}
