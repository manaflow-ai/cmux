import CmuxNextHistory
import Foundation
import Testing

struct BrowserVisitLogTests {
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func recordsListsAndUpdatesTitles() async {
        let log = BrowserVisitLog(url: nil, clock: { Self.t0 })
        await log.record(url: "https://a.example/1", title: nil, tab: "home/tab_1", at: Self.t0)
        await log.record(url: "https://b.example/", title: "B", tab: nil, at: Self.t0.addingTimeInterval(10))
        await log.updateTitle("A one", for: "https://a.example/1")
        let visits = await log.visits()
        #expect(visits.map(\.url) == ["https://b.example/", "https://a.example/1"])
        #expect(visits.last?.title == "A one" && visits.last?.tab == "home/tab_1")
    }

    @Test func searchMatchesURLAndTitleTokens() async {
        let log = BrowserVisitLog(url: nil)
        await log.record(url: "https://docs.swift.org/guide", title: "The Swift Guide", tab: nil, at: Self.t0)
        await log.record(url: "https://example.com/100%", title: "Percent", tab: nil, at: Self.t0)
        #expect(await log.visits(matching: "guide swift").count == 1)
        #expect(await log.visits(matching: "100%").count == 1)
        #expect(await log.visits(matching: "_").isEmpty)
    }

    @Test func summariesCountVisitsPerURL() async {
        let log = BrowserVisitLog(url: nil)
        for offset in 0..<3 { await log.record(url: "https://a/", title: "A\(offset)", tab: nil, at: Self.t0.addingTimeInterval(Double(offset))) }
        await log.record(url: "https://b/", title: nil, tab: nil, at: Self.t0)
        let summaries = await log.summaries()
        #expect(summaries.first?.url == "https://a/" && summaries.first?.visitCount == 3 && summaries.first?.title == "A2")
    }

    @Test func removesByURLHostAndRange() async {
        let log = BrowserVisitLog(url: nil)
        await log.record(url: "https://mail.example.com/x", title: nil, tab: nil, at: Self.t0)
        await log.record(url: "https://example.com/", title: nil, tab: nil, at: Self.t0.addingTimeInterval(5))
        await log.record(url: "https://other.org/", title: nil, tab: nil, at: Self.t0.addingTimeInterval(3600))
        #expect(await log.remove(host: "example.com") == 2)
        await log.record(url: "https://recent.org/", title: nil, tab: nil, at: Self.t0.addingTimeInterval(7200))
        #expect(await log.removeVisits(since: Self.t0.addingTimeInterval(7000)) == 1)
        #expect(await log.visits().map(\.url) == ["https://other.org/"])
        #expect(await log.removeVisits(since: nil) == 1)
        #expect(await log.count() == 0)
    }

    @Test func pruneDropsVisitsPastRetention() async {
        let now = Self.t0
        let log = BrowserVisitLog(url: nil, clock: { now })
        await log.record(url: "https://old/", title: nil, tab: nil, at: now.addingTimeInterval(-BrowserVisitLog.retention - 60))
        await log.record(url: "https://new/", title: nil, tab: nil, at: now)
        #expect(await log.prune() == 1)
        #expect(await log.visits().map(\.url) == ["https://new/"])
    }

    @Test func persistsAcrossInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = BrowserVisitLog.fileURL(profile: "default", supportDirectory: directory)
        #expect(file.path.hasSuffix("BrowserProfiles/default/History.sqlite"))
        do {
            let log = BrowserVisitLog(url: file)
            await log.record(url: "https://kept/", title: "Kept", tab: nil, at: Self.t0)
        }
        let reopened = BrowserVisitLog(url: file)
        #expect(await reopened.visits().first?.title == "Kept")
    }
}
