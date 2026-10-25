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

    /// Feeds `steps` to a new gate and returns which it admitted.
    static func admitted(_ steps: [(BrowserNavigationID?, BrowserLoadPhase)]) -> [Bool] {
        var gate = CEFDocumentGate()
        return steps.map { gate.admits(document: $0.0, phase: $0.1) }
    }

    @Test func aDocumentIsServedOnceAtCommitAndOnceAtFinish() {
        let admitted = Self.admitted([(Self.first, .committed), (Self.first, .committed), (Self.first, .finished), (Self.first, .finished)])
        #expect(admitted == [true, false, true, false])
    }

    /// A same-document navigation: CEF's loading state flips (provisional, then finished) and the
    /// address changes, but no document commits.
    @Test func aSameDocumentNavigationIsNotServedAgain() {
        let pushStates = Array(repeating: [(Self.first, BrowserLoadPhase.provisional), (Self.first, .finished)], count: 5).flatMap { $0 }
        let admitted = Self.admitted([(Self.first, .committed), (Self.first, .finished)] + pushStates)
        #expect(admitted.prefix(2) == [true, true])
        #expect(!admitted.dropFirst(2).contains(true), "a pushState sent the document calls again")
    }

    /// A commit and a finish in one main-actor turn coalesce into one observation of `.finished`:
    /// the new document is still served.
    @Test func aNewDocumentIsServedEvenWhenItsCommitWasNotSeen() {
        #expect(Self.admitted([(Self.first, .finished), (Self.second, .finished)]) == [true, true])
    }

    @Test func otherPhasesAreNeverServed() {
        #expect(Self.admitted([(nil, .idle), (nil, .provisional), (nil, .finished)]) == [false, false, true])
    }
}
