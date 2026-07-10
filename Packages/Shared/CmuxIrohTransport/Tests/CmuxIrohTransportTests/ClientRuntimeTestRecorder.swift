@testable import CmuxIrohTransport

actor ClientRuntimeTestRecorder {
    private var bindingCount = 0
    private var relayCount = 0
    private var localWipeEndpointWasClosed: [Bool] = []

    func recordBinding() {
        bindingCount += 1
    }

    func recordRelay() {
        relayCount += 1
    }

    func recordLocalWipe(endpointWasClosed: Bool) {
        localWipeEndpointWasClosed.append(endpointWasClosed)
    }

    func observedBindingCount() -> Int { bindingCount }
    func observedRelayCount() -> Int { relayCount }
    func observedLocalWipes() -> [Bool] { localWipeEndpointWasClosed }
}
