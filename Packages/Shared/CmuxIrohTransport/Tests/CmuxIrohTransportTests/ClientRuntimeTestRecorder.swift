@testable import CmuxIrohTransport

actor ClientRuntimeTestRecorder {
    private struct RelayWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var bindingCount = 0
    private var relayCount = 0
    private var localWipeEndpointWasClosed: [Bool] = []
    private var cachedBindingDeviceIDs: [[String]] = []
    private var policyInvalidationCount = 0
    private var relayWaiters: [RelayWaiter] = []

    func recordBinding() {
        bindingCount += 1
    }

    func recordRelay() {
        relayCount += 1
        let ready = relayWaiters.filter { relayCount >= $0.target }
        relayWaiters.removeAll { relayCount >= $0.target }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func waitForRelayCount(_ target: Int) async {
        guard relayCount < target else { return }
        await withCheckedContinuation { continuation in
            relayWaiters.append(RelayWaiter(target: target, continuation: continuation))
        }
    }

    func recordLocalWipe(endpointWasClosed: Bool) {
        localWipeEndpointWasClosed.append(endpointWasClosed)
    }

    func recordCachedBindings(_ bindings: [CmxIrohBrokerBinding]) {
        cachedBindingDeviceIDs.append(bindings.map(\.deviceID))
    }

    func recordPolicyInvalidation() {
        policyInvalidationCount += 1
    }

    func observedBindingCount() -> Int { bindingCount }
    func observedRelayCount() -> Int { relayCount }
    func observedLocalWipes() -> [Bool] { localWipeEndpointWasClosed }
    func observedCachedBindingDeviceIDs() -> [[String]] { cachedBindingDeviceIDs }
    func observedPolicyInvalidationCount() -> Int { policyInvalidationCount }
}
