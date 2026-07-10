@testable import CmuxIrohTransport

actor ClientRuntimeTestRecorder {
    private var bindingCount = 0
    private var relayCount = 0
    private var localWipeEndpointWasClosed: [Bool] = []
    private var cachedBindingDeviceIDs: [[String]] = []
    private var policyInvalidationCount = 0

    func recordBinding() {
        bindingCount += 1
    }

    func recordRelay() {
        relayCount += 1
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
