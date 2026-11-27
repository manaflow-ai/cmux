@testable import CmuxNextDiff
import Testing

/// A remote machine's patch is untrusted text: a hunk header it cannot parse is "too large",
/// never an abort (`@@ @@` used to slice `3..<2`).
@MainActor
struct RemoteDiffHunkHeaderTests {
    @Test func aHeaderWithNoRangesIsRejected() {
        #expect(DiffPageProvider.hunkCounts("@@ @@") == nil)
        #expect(DiffPageProvider.hunkCounts("@@ @@ trailing") == nil)
        #expect(DiffPageProvider.hunkCounts("@@  @@") == nil)
        #expect(DiffPageProvider.hunkCounts("@@ ") == nil)
    }

    @Test func aRealHeaderGivesItsCounts() {
        let counts = DiffPageProvider.hunkCounts("@@ -1,2 +1,3 @@ func f()")
        #expect(counts?.old == 2)
        #expect(counts?.new == 3)
    }
}
