@testable import CmuxNextBrowser
import Foundation
import Testing

/// The Chromium verification bridge's DevTools traffic per document. The detector found waiting
/// before its binding existed keeps no timer: it reports at the bridge's ready call. That call
/// goes after the binding add at `.committed` (a page whose load never ends still gets it) and
/// again at `.finished` (after the detector's first check at DOMContentLoaded).
@Suite struct CEFVerificationBridgeCallsTests {
    static func methods(_ phase: BrowserLoadPhase) -> [String] {
        CEFVerificationBridge.documentCalls(phase: phase).map(\.method)
    }

    static func readyCalls(_ phase: BrowserLoadPhase) -> Int {
        CEFVerificationBridge.documentCalls(phase: phase).filter {
            if case .readyHook = $0 { true } else { false }
        }.count
    }

    /// A page whose load never ends (a long poll, a stuck subresource) never reaches `.finished`:
    /// its commit must already bring the ready call. Before, it came only at `.finished`.
    @Test func aCommitAddsTheBindingThenOneReadyCall() {
        #expect(Self.methods(.committed).first == "Runtime.addBinding")
        #expect(Self.readyCalls(.committed) == 1)
    }

    @Test func aFinishedDocumentGetsTheBindingAndOneReadyCall() {
        #expect(Self.methods(.finished).first == "Runtime.addBinding")
        #expect(Self.readyCalls(.finished) == 1)
    }
}
