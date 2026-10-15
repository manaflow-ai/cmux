import CmuxBrowser
import Testing
@testable import CmuxCEFBrowser

/// Holds the Chromium adapter to the engine parity checklist, as
/// `BrowserEngineParityChecklistTests` holds WebKit: a capability the adapter
/// gains or drops must change the checklist in the same change.
@MainActor
@Suite
struct CEFEngineParityTests {
    private let checklist = BrowserEngineParityChecklist.standard

    @Test func chromiumDeclaresExactlyItsChecklistColumn() {
        #expect(checklist.mismatches(declared: CEFBrowserPage.engineCapabilities, engine: .chromium) == [])
    }

    /// Every open Chromium gap names its owner, so the parity matrix row can
    /// point at who closes it.
    @Test func chromiumGapsNameTheirOwners() {
        for (name, owner) in checklist.gaps(of: .chromium) {
            #expect(!owner.isEmpty, "\(name) has no owner")
        }
    }
}
