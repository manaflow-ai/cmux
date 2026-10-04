import CmuxNextHistory
import Foundation
import Testing

struct HistoryQueryTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func page(_ id: String, _ title: String, url: String, ago: TimeInterval) -> HistoryEntry {
        HistoryEntry(id: "page:\(id)", kind: .page, time: now.addingTimeInterval(-ago), title: title, detail: url,
                     payload: .page(url: url, profile: "default"))
    }

    static func agent(_ id: String, provider: String, cwd: String, ago: TimeInterval) -> HistoryEntry {
        let time = now.addingTimeInterval(-ago)
        let session = AgentSession(machine: "home", provider: provider, sessionID: id, cwd: cwd, workspace: "api",
                                   startedAt: time, lastActivityAt: time)
        return HistoryEntry(id: "agent:\(id)", kind: .agent, time: time, title: provider, detail: cwd, payload: .agent(session))
    }

    static let sample = [
        page("1", "Swift Forums", url: "https://forums.swift.org/t/1", ago: 60),
        page("2", "Résumé tips", url: "https://example.com/resume", ago: 7200),
        agent("s-1", provider: "claude", cwd: "/Users/me/api", ago: 30),
        page("3", "Old page", url: "https://old.example.com", ago: 40 * 86_400),
    ]

    @Test func emptyQueryIsEverythingNewestFirst() {
        let ids = HistoryQuery().apply(to: Self.sample, now: Self.now).map(\.id)
        #expect(ids == ["agent:s-1", "page:1", "page:2", "page:3"])
    }

    @Test func tokensMatchInAnyOrderAcrossFields() {
        let ids = HistoryQuery(text: "forums SWIFT").apply(to: Self.sample, now: Self.now).map(\.id)
        #expect(ids == ["page:1"])
        #expect(HistoryQuery(text: "api claude").apply(to: Self.sample, now: Self.now).map(\.id) == ["agent:s-1"])
    }

    @Test func diacriticsFold() {
        #expect(HistoryQuery(text: "resume").apply(to: Self.sample, now: Self.now).map(\.id) == ["page:2"])
    }

    @Test func kindsRangeAndLimitFilter() {
        #expect(HistoryQuery(kinds: [.page], range: .hour).apply(to: Self.sample, now: Self.now).map(\.id) == ["page:1"])
        #expect(HistoryQuery(kinds: [.page], limit: 2).apply(to: Self.sample, now: Self.now).map(\.id) == ["page:1", "page:2"])
        #expect(HistoryQuery(range: .month).apply(to: Self.sample, now: Self.now).count == 3)
    }

    @Test func implementationPagesAndPlaceholderLocationsAreHidden() {
        let noise = [
            page("history", "History", url: "cmux://history", ago: 1),
            page("blank", "about:blank", url: "about:blank", ago: 2),
            HistoryEntry(id: "location:history", kind: .location, time: Self.now,
                         title: "History", detail: "cmux://history", payload: .location(
                            HistoryLocation(key: .init(machine: "home", tab: "tab"), window: "w", workspace: "ws", pane: "p",
                                            content: .browser, title: "History", url: "cmux://history"), isCurrent: false))
        ]
        #expect(HistoryQuery().apply(to: noise, now: Self.now).isEmpty)
    }

    @Test func todayStartsAtMidnight() throws {
        let interval = try #require(HistoryRange.today.interval(now: Self.now, calendar: Self.calendar))
        #expect(interval.start == Self.calendar.startOfDay(for: Self.now))
        #expect(HistoryRange.all.interval(now: Self.now) == nil)
    }

    @Test func groupsByDayKeepOrder() {
        let entries = HistoryQuery().apply(to: Self.sample, now: Self.now)
        let groups = HistoryGrouping.day.groups(entries, calendar: Self.calendar)
        #expect(groups.map { $0.entries.map(\.id) } == [["agent:s-1", "page:1", "page:2"], ["page:3"]])
    }

    @Test func groupsByWorkspace() {
        let entries = HistoryQuery().apply(to: Self.sample, now: Self.now)
        let groups = HistoryGrouping.workspace.groups(entries, calendar: Self.calendar)
        #expect(groups.first?.name == "api")
        #expect(groups.count == 2)
    }
}
