@testable import CmuxNextDesign
import Testing

/// A close's undo toast shows at most once per id in its gap (Lawrence 2026-10-18).
struct UndoToastRateLimitTests {
    @Test func aSecondCloseToastInTheGapIsKeptQuiet() {
        var limit = UndoToastRateLimit(minimumGap: .seconds(30))
        let start = ContinuousClock.now
        #expect(limit.allows("tab-closed", at: start))
        #expect(!limit.allows("tab-closed", at: start + .seconds(10)))
        #expect(!limit.allows("tab-closed", at: start + .seconds(29)))
        #expect(limit.allows("tab-closed", at: start + .seconds(31)))
    }

    @Test func eachIdHasItsOwnGap() {
        var limit = UndoToastRateLimit(minimumGap: .seconds(30))
        let start = ContinuousClock.now
        #expect(limit.allows("tab-closed", at: start))
        #expect(limit.allows("workspace-group-closed", at: start + .seconds(1)))
    }

    @Test func aQuietCloseDoesNotRestartTheGap() {
        var limit = UndoToastRateLimit(minimumGap: .seconds(30))
        let start = ContinuousClock.now
        #expect(limit.allows("tab-closed", at: start))
        #expect(!limit.allows("tab-closed", at: start + .seconds(20)))
        #expect(limit.allows("tab-closed", at: start + .seconds(30)))
    }

    @Test func aZeroGapNeverLimits() {
        var limit = UndoToastRateLimit(minimumGap: .zero)
        let start = ContinuousClock.now
        #expect(limit.allows("tab-closed", at: start))
        #expect(limit.allows("tab-closed", at: start))
    }
}
