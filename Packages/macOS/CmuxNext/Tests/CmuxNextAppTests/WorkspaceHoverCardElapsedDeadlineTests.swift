@testable import CmuxNextSidebar
import Foundation
import Testing

/// The hover card's running time arms one deadline for its next text change, not a periodic
/// tick (p14-energy-057): a second boundary under an hour, a minute boundary under a day, an
/// hour boundary after. The old one-minute repeat past an hour let "1h 3m" lag up to 59 s.
@MainActor @Suite struct WorkspaceHoverCardElapsedDeadlineTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func text(_ since: Date, at offset: TimeInterval) -> String {
        WorkspaceHoverCardContent.elapsed(since: since, now: Self.now.addingTimeInterval(offset))
    }

    /// (seconds running, seconds until the text changes).
    nonisolated static let cases: [(TimeInterval, TimeInterval)] = [
        (12.25, 0.75), // "12s": the next second
        (3599.5, 0.5), // "59m 59s" -> "1h"
        (3792.5, 47.5), // "1h 3m": the next minute, not a minute from now
        (100_925.5, 3474.5), // "1d 4h": the next hour
        (-5, 7), // a start ahead of this clock reads "1s" until two seconds have passed
        (0.25, 1.75),
    ]

    @Test(arguments: cases)
    func theDeadlineIsTheNextChangeOfTheShownText(running: TimeInterval, expected: TimeInterval) {
        let since = Self.now.addingTimeInterval(-running)
        let delay = WorkspaceHoverCardContent.nextElapsedChange(since: since, now: Self.now)
        #expect(abs(delay - expected) < 1e-6, "running \(running) s: next change in \(delay) s, expected \(expected) s")
        let shown = text(since, at: 0)
        #expect(text(since, at: delay - 0.01) == shown, "the text changed before the deadline")
        #expect(text(since, at: delay + 0.001) != shown, "the text did not change at the deadline")
    }

    @Test func pastAnHourTheTextHoldsForTheWholeMinute() {
        // 1h 3m 0.5s: the text must read the same until 1h 4m, whatever the formatter's rounding.
        let since = Self.now.addingTimeInterval(-(3600 + 3 * 60 + 0.5))
        let shown = text(since, at: 0)
        for offset in stride(from: 0.0, to: 59.0, by: 1) {
            #expect(text(since, at: offset) == shown, "the text changed \(offset) s into its minute")
        }
        #expect(text(since, at: 59.6) != shown)
    }
}
