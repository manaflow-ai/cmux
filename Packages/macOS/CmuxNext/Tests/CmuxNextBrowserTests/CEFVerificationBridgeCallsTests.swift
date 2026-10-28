@testable import CmuxNextBrowser
import Foundation
import Testing

/// The Chromium verification bridge's DevTools traffic per document. The detector's ready call is
/// two round trips (add a run-immediately script, remove it); sent at every phase change it made
/// each navigation of every Chromium tab cost 6 calls where 2 did. It is needed once per document,
/// after the detector's first check: at `.finished`. A commit re-adds only the binding.
@Suite struct CEFVerificationBridgeCallsTests {
    static func methods(_ phase: BrowserLoadPhase) -> [String] {
        CEFVerificationBridge.documentCalls(phase: phase).map(\.0)
    }

    static func readyCalls(_ phase: BrowserLoadPhase) -> Int {
        CEFVerificationBridge.documentCalls(phase: phase).filter { $0.0 == "Page.addScriptToEvaluateOnNewDocument" }.count
    }

    @Test func aCommitAddsOnlyTheBinding() {
        #expect(Self.methods(.committed) == ["Runtime.addBinding"])
    }

    @Test func aFinishedDocumentGetsTheBindingAndOneReadyCall() {
        #expect(Self.methods(.finished).first == "Runtime.addBinding")
        #expect(Self.readyCalls(.finished) == 1)
    }

    @Test func aDocumentGetsOneReadyCallInAll() {
        #expect(Self.readyCalls(.committed) + Self.readyCalls(.finished) == 1)
    }
}
