@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// A close's undo toast shows at most once per id in its gap (Lawrence 2026-10-18).
struct UndoToastRateLimitTests {
    /// The answers of `limit` for `asks` (id and seconds after a fixed start), in order.
    private static func answers(_ limit: inout UndoToastRateLimit, _ asks: [(String, Int)]) -> [Bool] {
        let start = ContinuousClock.now
        return asks.map { limit.allows($0.0, at: start + .seconds($0.1)) }
    }

    @Test func aSecondCloseToastInTheGapIsKeptQuiet() {
        var limit = UndoToastRateLimit(minimumGap: .seconds(30))
        let got = Self.answers(&limit, [("tab-closed", 0), ("tab-closed", 10), ("tab-closed", 29), ("tab-closed", 31)])
        #expect(got == [true, false, false, true])
    }

    @Test func eachIdHasItsOwnGap() {
        var limit = UndoToastRateLimit(minimumGap: .seconds(30))
        let got = Self.answers(&limit, [("tab-closed", 0), ("workspace-group-closed", 1)])
        #expect(got == [true, true])
    }

    @Test func aQuietCloseDoesNotRestartTheGap() {
        var limit = UndoToastRateLimit(minimumGap: .seconds(30))
        let got = Self.answers(&limit, [("tab-closed", 0), ("tab-closed", 20), ("tab-closed", 30)])
        #expect(got == [true, false, true])
    }

    @Test func aZeroGapNeverLimits() {
        var limit = UndoToastRateLimit(minimumGap: .zero)
        let got = Self.answers(&limit, [("tab-closed", 0), ("tab-closed", 0)])
        #expect(got == [true, true])
    }
}
