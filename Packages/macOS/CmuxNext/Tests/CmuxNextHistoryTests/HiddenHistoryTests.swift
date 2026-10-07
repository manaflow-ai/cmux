import CmuxNextHistory
import Foundation
import Testing

struct HiddenHistoryTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func clearHidesTheRangeButNotLaterActivity() {
        var hidden = HiddenHistory()
        hidden.hide(since: Self.now.addingTimeInterval(-3600), now: Self.now)
        #expect(hidden.hides("a", activeAt: Self.now.addingTimeInterval(-60)))
        #expect(!hidden.hides("a", activeAt: Self.now.addingTimeInterval(-7200)))
        #expect(!hidden.hides("a", activeAt: Self.now.addingTimeInterval(60)))
        hidden.hide(since: nil, now: Self.now)
        #expect(hidden.hides("b", activeAt: .distantPast.addingTimeInterval(1)))
    }

    @Test func singleEntriesStayHiddenAndRoundTrip() throws {
        var hidden = HiddenHistory()
        hidden.hide(entry: "local/claude/x")
        hidden.hide(entry: "local/claude/x")
        #expect(hidden.entries == ["local/claude/x"])
        let decoded = try JSONDecoder().decode(HiddenHistory.self, from: JSONEncoder().encode(hidden))
        #expect(decoded.hides("local/claude/x", activeAt: Self.now.addingTimeInterval(1e6)))
    }

    @Test func aKindedClearHidesOnlyThatKind() {
        var hidden = HiddenHistory()
        hidden.hide(since: nil, now: Self.now, kind: "command")
        #expect(hidden.hides("c", activeAt: Self.now.addingTimeInterval(-5), kind: "command"))
        #expect(!hidden.hides("a", activeAt: Self.now.addingTimeInterval(-5), kind: "agent"))
    }

    @Test func mergeKeepsEveryClear() {
        var a = HiddenHistory()
        a.hide(entry: "one")
        var b = HiddenHistory()
        b.hide(since: Self.now.addingTimeInterval(-10), now: Self.now)
        let merged = a.merged(with: b)
        #expect(merged.hides("one", activeAt: .distantPast))
        #expect(merged.hides("two", activeAt: Self.now.addingTimeInterval(-5)))
    }
}
