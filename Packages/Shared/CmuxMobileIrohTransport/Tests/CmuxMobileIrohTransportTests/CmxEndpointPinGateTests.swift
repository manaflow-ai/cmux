import Testing
@testable import CmuxMobileIrohTransport

private let gate = CmxEndpointPinGate()
private let macA = "z32-endpoint-id-mac-a"
private let macB = "z32-endpoint-id-mac-b"

@Test func noPinYieldsFirstTrustAndPinsIt() {
    let decision = gate.evaluate(dialedEndpointID: macA, pinnedEndpointID: nil)
    #expect(decision == .firstTrust(macA))
    #expect(gate.allowsStackTokens(for: decision))
    #expect(gate.endpointIDToPin(for: decision) == macA)
}

@Test func emptyPinIsTreatedAsNoPin() {
    let decision = gate.evaluate(dialedEndpointID: macA, pinnedEndpointID: "")
    #expect(decision == .firstTrust(macA))
}

@Test func matchingPinIsTrustedAndNeedsNoRewrite() {
    let decision = gate.evaluate(dialedEndpointID: macA, pinnedEndpointID: macA)
    #expect(decision == .trusted)
    #expect(gate.allowsStackTokens(for: decision))
    #expect(gate.endpointIDToPin(for: decision) == nil)
}

@Test func changedPinRefusesTokensAndDoesNotAutoPin() {
    let decision = gate.evaluate(dialedEndpointID: macB, pinnedEndpointID: macA)
    #expect(decision == .mismatch(pinned: macA, dialed: macB))
    #expect(!gate.allowsStackTokens(for: decision))
    #expect(gate.endpointIDToPin(for: decision) == nil)
}
