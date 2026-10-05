import Foundation
import Testing
@testable import CmuxUpdaterUI

@Suite struct UpdateSummaryTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US")

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // The shape scripts/ci/nightly_release_notes.py writes into <description>.
    private let nightlyFeed = """
    Show the top changes in the update popover (#17460)
    Keep the sidebar order after a crash (#17455)
    Fix a focus jump when closing a split (#17450)
    Restore browser zoom per site (#17441)
    Speed up workspace switching (#17432)
    and 18 more
    Infrastructure: 7
    """

    @Test func nightlyListsFiveChangesAndCountsTheRest() {
        let summary = UpdateSummary(
            displayVersion: "0.65.0-nightly.3737789529201",
            date: date(5, 12, 20),
            itemDescription: nightlyFeed,
            now: date(5, 18, 0),
            locale: locale,
            timeZone: utc
        )
        #expect(summary.changes == [
            "Show the top changes in the update popover",
            "Keep the sidebar order after a crash",
            "Fix a focus jump when closing a split",
            "Restore browser zoom per site",
            "Speed up workspace switching",
        ])
        #expect(summary.remainingCount == 18)
        #expect(summary.headline.hasPrefix("Nightly · Today"))
        #expect(summary.headline.hasSuffix(" · 23 changes"))
        #expect(!summary.headline.contains("3737789529201"))
    }

    @Test func olderNightlyShowsItsDayInsteadOfToday() {
        let summary = UpdateSummary(
            displayVersion: "0.65.0-nightly.3735594566602",
            date: date(1, 9, 5),
            itemDescription: nil,
            now: date(5, 18, 0),
            locale: locale,
            timeZone: utc
        )
        #expect(summary.headline.hasPrefix("Nightly · Oct 1"))
        #expect(summary.changes.isEmpty)
    }

    @Test func stableShowsVersionAndDay() {
        let summary = UpdateSummary(
            displayVersion: "0.65.1",
            date: date(5, 15, 0),
            itemDescription: nil,
            locale: locale,
            timeZone: utc
        )
        #expect(summary.headline == "0.65.1 · Oct 5")
        #expect(summary.changes.isEmpty)
        #expect(summary.remainingCount == 0)
    }

    @Test func emptyRangeListsNothing() {
        let summary = UpdateSummary(
            displayVersion: "0.65.0-nightly.3737789529201",
            date: nil,
            itemDescription: "No product PRs merged since the previous published build.",
            locale: locale,
            timeZone: utc
        )
        #expect(summary.changes.isEmpty)
        #expect(summary.headline == "Nightly")
    }

    @Test func infrastructureOnlyCountsNoChanges() {
        let parsed = UpdateSummary.parse("Infrastructure: 4")
        #expect(parsed.titles.isEmpty)
        #expect(parsed.total == 0)
    }

    @Test func shortListHasNoRemainder() {
        let summary = UpdateSummary(
            displayVersion: "0.65.0-nightly.1",
            date: nil,
            itemDescription: "Fix a crash on launch (#17001)\nInfrastructure: 2",
            locale: locale,
            timeZone: utc
        )
        #expect(summary.changes == ["Fix a crash on launch"])
        #expect(summary.remainingCount == 0)
    }
}
