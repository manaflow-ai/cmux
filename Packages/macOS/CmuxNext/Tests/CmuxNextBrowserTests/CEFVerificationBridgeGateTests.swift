@testable import CmuxNextBrowser
import Foundation
import Testing

/// The verification bridge's real per-change decision (`CEFVerificationBridge.callsOnChange`),
/// through its own gate: the calls it sends for a sequence of tab states.
@Suite struct CEFVerificationBridgeGateTests {
    static func calls(_ steps: [(BrowserNavigationID?, BrowserLoadPhase)]) -> Int {
        var gate = CEFDocumentGate()
        return steps.reduce(0) { $0 + CEFVerificationBridge.callsOnChange(document: $1.0, phase: $1.1, gate: &gate).count }
    }

    @Test func pushStatesOfAFinishedPageSendNoCalls() {
        let id = BrowserNavigationID(rawValue: 7)
        let load = Self.calls([(id, .committed), (id, .finished)])
        let withPushStates = Self.calls([(id, .committed), (id, .finished), (id, .finished), (id, .provisional), (id, .finished)])
        #expect(load == 4, "binding + ready call at commit, and again at finish")
        #expect(withPushStates == load)
    }
}
