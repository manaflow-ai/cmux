import Foundation
import Testing
import WebKit
@testable import CmuxNextBrowser

final class FakeDataStoreFactory: WebsiteDataStoreFactory {
    var made: [UUID] = []
    var removed: [UUID] = []

    func makeStore(identifier: UUID) -> WKWebsiteDataStore {
        made.append(identifier)
        return .nonPersistent()
    }

    func removeStore(identifier: UUID) async throws {
        removed.append(identifier)
    }
}

@Suite struct ProfileStoreTests {
    @Test func oneStorePerProfileKeyedByProfileUUID() {
        let factory = FakeDataStoreFactory()
        let store = WebKitProfileStore(factory: factory)
        let work = BrowserProfileID(rawValue: UUID())

        let defaultStore = store.dataStore(for: .default)
        #expect(store.dataStore(for: .default) === defaultStore)
        let workStore = store.dataStore(for: work)
        #expect(workStore !== defaultStore)
        #expect(store.dataStore(for: work) === workStore)

        #expect(factory.made == [BrowserProfileID.default.rawValue, work.rawValue])
        #expect(store.loadedProfiles == [.default, work])
    }

    @Test func removingDataDropsTheCachedStore() async throws {
        let factory = FakeDataStoreFactory()
        let store = WebKitProfileStore(factory: factory)
        let profile = BrowserProfileID(rawValue: UUID())
        let first = store.dataStore(for: profile)
        try await store.removeData(for: profile)
        #expect(factory.removed == [profile.rawValue])
        #expect(!store.loadedProfiles.contains(profile))
        #expect(store.dataStore(for: profile) !== first)
    }

    @Test func defaultProfileHasAStableIdentity() throws {
        let data = try JSONEncoder().encode(BrowserProfileID.default)
        #expect(try JSONDecoder().decode(BrowserProfileID.self, from: data) == .default)
        #expect(BrowserProfileID.default.rawValue.uuidString == "8E5C0D1F-2B7A-4F3C-9A61-5D2E7B0C4A11")
    }
}

@Suite struct SupportTests {
    @Test func downloadDestinationsAreUniqueAndConfined() {
        let directory = URL(filePath: "/tmp/dl", directoryHint: .isDirectory)
        var existing: Set<String> = ["/tmp/dl/report.pdf", "/tmp/dl/report (1).pdf", "/tmp/dl/README"]
        let exists: (URL) -> Bool = { existing.contains($0.path(percentEncoded: false)) }

        #expect(DownloadDestination.uniqueURL(in: directory, suggestedFilename: "report.pdf", exists: exists)?.lastPathComponent == "report (2).pdf")
        #expect(DownloadDestination.uniqueURL(in: directory, suggestedFilename: "README", exists: exists)?.lastPathComponent == "README (1)")
        #expect(DownloadDestination.uniqueURL(in: directory, suggestedFilename: "../../etc/passwd", exists: exists)?.path(percentEncoded: false) == "/tmp/dl/passwd")
        #expect(DownloadDestination.sanitizedFilename(".hidden") == "hidden")
        #expect(DownloadDestination.sanitizedFilename("a:b.txt") == "a-b.txt")
        #expect(DownloadDestination.sanitizedFilename("  ") == "download")
        existing.removeAll()
    }

    @Test func findStateTracksPositionWithWraparound() {
        var find = FindState()
        #expect(find.step(query: "a", direction: .forward, matchFound: true, count: 3).currentIndex == 1)
        #expect(find.step(query: "a", direction: .forward, matchFound: true, count: 3).currentIndex == 2)
        #expect(find.step(query: "a", direction: .forward, matchFound: true, count: 3).currentIndex == 3)
        #expect(find.step(query: "a", direction: .forward, matchFound: true, count: 3).currentIndex == 1)
        #expect(find.step(query: "a", direction: .backward, matchFound: true, count: 3).currentIndex == 3)
        #expect(find.step(query: "ab", direction: .backward, matchFound: true, count: 2).currentIndex == 2)
        let miss = find.step(query: "zz", direction: .forward, matchFound: false, count: 0)
        #expect(!miss.matchFound)
        #expect(miss.currentIndex == nil)
    }

    @Test func jsValuesConvertFromFoundation() {
        #expect(BrowserJSValue(foundation: nil) == .null)
        #expect(BrowserJSValue(foundation: NSNumber(value: true)) == .bool(true))
        #expect(BrowserJSValue(foundation: NSNumber(value: 2.5)) == .number(2.5))
        #expect(BrowserJSValue(foundation: ["a": [1, "x", NSNull()]] as [String: Any])
            == .object(["a": .array([.number(1), .string("x"), .null])]))
        #expect(BrowserJSValue.string("s").stringValue == "s")
    }

    @Test func newTabDispositionFromModifiers() {
        #expect(WebKitTab.isWebScheme(URL(string: "https://x.example")!))
        #expect(!WebKitTab.isWebScheme(URL(string: "mailto:a@b.c")!))
        #expect(!WebKitTab.isWebScheme(URL(string: "zoommtg://join")!))
    }
}

@Suite struct SuggestionTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func entry(_ url: String, _ title: String?, visits: Int = 1, daysAgo: Double = 0) -> BrowserHistoryEntry {
        BrowserHistoryEntry(url: URL(string: url)!, title: title, visitCount: visits, lastVisit: now.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test func hostPrefixBeatsTitleAndSubstringMatches() throws {
        let github = entry("https://github.com/", "GitHub")
        let article = entry("https://blog.example/why-git-rocks", "Using git well")
        let digit = entry("https://example.com/digits", "Digits")
        let host = try #require(BrowserHistoryRanker.score(github, for: "git", now: now))
        let title = try #require(BrowserHistoryRanker.score(article, for: "git", now: now))
        let substring = try #require(BrowserHistoryRanker.score(digit, for: "git", now: now))
        #expect(host > title)
        #expect(title > substring)
        #expect(BrowserHistoryRanker.score(github, for: "gitlab", now: now) == nil)
        #expect(BrowserHistoryRanker.score(github, for: "", now: now) == nil)
    }

    @Test func frequencyAndRecencyBreakTies() throws {
        let often = try #require(BrowserHistoryRanker.score(entry("https://a.example/x", "Docs", visits: 40), for: "docs", now: now))
        let once = try #require(BrowserHistoryRanker.score(entry("https://b.example/x", "Docs", visits: 1), for: "docs", now: now))
        let stale = try #require(BrowserHistoryRanker.score(entry("https://c.example/x", "Docs", visits: 1, daysAgo: 90), for: "docs", now: now))
        #expect(often > once)
        #expect(once > stale)
    }

    @Test func everyTokenMustMatch() {
        let page = entry("https://developer.apple.com/documentation/webkit", "WebKit | Apple Developer")
        #expect(BrowserHistoryRanker.score(page, for: "apple webkit", now: now) != nil)
        #expect(BrowserHistoryRanker.score(page, for: "apple chromium", now: now) == nil)
    }

    @Test func historyStoreMergesEquivalentURLs() {
        let history = InMemoryBrowserHistory()
        history.recordVisit(url: URL(string: "https://www.example.com/")!, title: "Example", at: now)
        history.recordVisit(url: URL(string: "http://example.com")!, title: nil, at: now)
        history.recordVisit(url: URL(string: "about:blank")!, title: nil, at: now)
        #expect(history.entries.count == 1)
        #expect(history.entries[0].visitCount == 2)
        #expect(history.entries[0].title == "Example")
    }

    @Test func engineListsTypedDestinationFirstAndDedupes() async {
        let history = InMemoryBrowserHistory(entries: [
            entry("https://github.com/", "GitHub", visits: 10),
            entry("https://github.com/manaflow-ai/cmux", "cmux", visits: 3),
            entry("https://gist.github.com/", "Gists"),
        ])
        final class Completions: BrowserSearchCompletionSource {
            func completions(for query: String) async -> [String] { [query, "\(query) desktop", "\(query) copilot"] }
        }
        let resolver = OmniboxResolver(searchEngine: .google)
        let engine = OmniboxSuggestionEngine(
            resolver: resolver,
            providers: [
                HistorySuggestionProvider(store: history, now: { self.now }),
                SearchSuggestionProvider(searchEngine: .google, source: Completions()),
            ],
            maxResults: 5
        )

        let typedURL = await engine.suggestions(for: "github.com")
        #expect(typedURL.first?.kind == .navigate)
        #expect(typedURL.first?.url.absoluteString == "https://github.com")
        // github.com from history is the same destination as the typed row.
        #expect(typedURL.filter { BrowserHistoryRanker.dedupeKey(for: $0.url) == "github.com" }.count == 1)

        let query = await engine.suggestions(for: "git")
        #expect(query.first?.kind == .search)
        #expect(query.first?.title == "git")
        #expect(query.count == 5)
        #expect(query[1].kind == .history)
        #expect(query[1].url.absoluteString == "https://github.com/")
        #expect(!query.dropFirst().contains { $0.kind == .search && $0.title == "git" })

        #expect(await engine.suggestions(for: "   ").isEmpty)
    }
}
