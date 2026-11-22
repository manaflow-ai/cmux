import Foundation
@testable import CmuxNextPalette
import Testing

/// A missing ranker bundle fails loudly (cx-6so.52 follow-up): the palette test support records
/// one issue that names the fix and skips the body, and the searcher keeps and logs the reason
/// instead of answering every query with no rows in silence.
@Suite struct PaletteRankerRequiredTests {
    @Test func aMissingBundleFailsFastWithTheFix() async throws {
        let trait = PaletteRankerRequired(loadError: { .resourceMissing })
        let test = try #require(Test.current)
        let ran = Flag()
        try await withKnownIssue {
            try await trait.provideScope(for: test, testCase: nil) { await ran.set() }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.hasPrefix(PaletteRankerRequired.missing) }
        }
        #expect(await ran.value == false, "the body does not run without the bundle")
    }

    @Test func aLoadedBundleRunsTheBody() async throws {
        let trait = PaletteRankerRequired(loadError: { nil })
        let test = try #require(Test.current)
        let ran = Flag()
        try await trait.provideScope(for: test, testCase: nil) { await ran.set() }
        #expect(await ran.value)
    }

    @Test func aSearcherWhoseBundleCannotLoadKeepsTheReason() async {
        let searcher = PaletteSearcher(loading: { throw PaletteRankerBridgeError.resourceMissing })
        guard case .resourceMissing? = searcher.loadError else {
            Issue.record("expected resourceMissing, got \(String(describing: searcher.loadError))")
            return
        }
    }
}

/// Whether a scope ran its body.
actor Flag {
    private(set) var value = false
    func set() { value = true }
}
