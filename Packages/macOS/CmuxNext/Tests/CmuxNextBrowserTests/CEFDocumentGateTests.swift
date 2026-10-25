@testable import CmuxNextBrowser
import Foundation
import Testing

/// The gate both Chromium document bridges run their per-document DevTools calls through
/// (`CEFDocumentGate`). Before, the verification bridge keyed it on the address: every
/// `pushState` or `replaceState` of a finished page sent the binding add and the ready call again
/// (3 DevTools calls on the main thread each time).
@Suite struct CEFDocumentGateTests {
    static let first = BrowserNavigationID(rawValue: 1)
    static let second = BrowserNavigationID(rawValue: 2)

    @Test func aDocumentIsServedOnceAtCommitAndOnceAtFinish() {
        var gate = CEFDocumentGate()
        #expect(gate.admits(document: Self.first, phase: .committed))
        #expect(!gate.admits(document: Self.first, phase: .committed))
        #expect(gate.admits(document: Self.first, phase: .finished))
        #expect(!gate.admits(document: Self.first, phase: .finished))
    }

    /// A same-document navigation: CEF's loading state flips (provisional, then finished) and the
    /// address changes, but no document commits.
    @Test func aSameDocumentNavigationIsNotServedAgain() {
        var gate = CEFDocumentGate()
        _ = gate.admits(document: Self.first, phase: .committed)
        _ = gate.admits(document: Self.first, phase: .finished)
        for _ in 0..<5 {
            #expect(!gate.admits(document: Self.first, phase: .provisional))
            #expect(!gate.admits(document: Self.first, phase: .finished), "a pushState sent the document calls again")
        }
    }

    /// A commit and a finish in one main-actor turn coalesce into one observation of `.finished`:
    /// the new document is still served.
    @Test func aNewDocumentIsServedEvenWhenItsCommitWasNotSeen() {
        var gate = CEFDocumentGate()
        _ = gate.admits(document: Self.first, phase: .finished)
        #expect(gate.admits(document: Self.second, phase: .finished))
    }

    @Test func otherPhasesAreNeverServed() {
        var gate = CEFDocumentGate()
        #expect(!gate.admits(document: nil, phase: .idle))
        #expect(!gate.admits(document: nil, phase: .provisional))
        #expect(gate.admits(document: nil, phase: .finished))
    }
}

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
