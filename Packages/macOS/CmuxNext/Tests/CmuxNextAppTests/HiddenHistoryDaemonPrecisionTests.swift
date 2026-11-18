import CmuxNextHistory
import Foundation
import Testing

/// cmux#38381: a local Clear History hide keeps fractional-second Dates while the daemon stores whole
/// milliseconds, so after a reconnect `merged(with:)` kept both copies of the same clear.
struct HiddenHistoryDaemonPrecisionTests {
    /// The daemon's copy of `range`: Unix milliseconds rounded, read back as seconds (cmux-history `unix_ms`).
    static func daemonCopy(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    @Test func localHideMergedWithItsDaemonCopyIsOneRange() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000.123_456_7)
        let since = Date(timeIntervalSince1970: 1_759_990_000.987_654_3)
        var local = HiddenHistory()
        local.hide(since: since, now: now, kind: "agent")
        var daemon = HiddenHistory()
        let stored = try #require(local.ranges.first)
        daemon.hide(since: Self.daemonCopy(since), now: Self.daemonCopy(now), kind: "agent")
        #expect(local.merged(with: daemon).ranges.count == 1)
        #expect(daemon.merged(with: local).ranges.count == 1)
        #expect(stored.until == Self.daemonCopy(now))
    }

    @Test func allTimeHideMergedWithItsDaemonCopyIsOneRange() {
        let now = Date(timeIntervalSince1970: 1_760_000_000.000_4)
        var local = HiddenHistory()
        local.hide(since: nil, now: now)
        var daemon = HiddenHistory()
        daemon.hide(since: Self.daemonCopy(.distantPast), now: Self.daemonCopy(now))
        #expect(local.merged(with: daemon).ranges.count == 1)
    }
}
