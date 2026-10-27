import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserHistory
import CmuxNextDaemon
import Foundation
import Testing

/// Task p01-process-093: the tab's `frontend-browser-history-v1` record has each entry's page state
/// (`page_state`), only under the engine state's privacy rules, within the record's bound with the
/// shown entry's kept first, and a restore gives the entries back with theirs.
@MainActor
struct BrowserPageStateHistoryTests {
    final class Sent {
        var histories: [FrontendBrowserHistory] = []
    }

    /// The record's wire: `page_state` per entry, absent when none.
    @Test func eachEntryCarriesItsPageStateOnTheWire() throws {
        let history = FrontendBrowserHistory(entries: [.init(url: "https://example.com/a", pageState: "AA/+=="),
                                                       .init(url: "https://example.com/b")], index: 1)
        let json = try #require(String(data: try JSONEncoder().encode(history), encoding: .utf8))
        #expect(json.contains("\"page_state\""))
        let decoded = try JSONDecoder().decode(FrontendBrowserHistory.self, from: Data(json.utf8))
        #expect(decoded == history)
        #expect(decoded.withoutPageStates().entries.allSatisfy { $0.pageState == nil })
    }

    /// Past the bound, the page states of the entries farthest from the shown one go first.
    @Test func pageStatesPastTheBoundDropFarthestFirst() {
        let state = String(repeating: "A", count: 20_000)
        let history = FrontendBrowserHistory(entries: (0 ..< 5).map { .init(url: "https://example.com/\($0)", pageState: state) }, index: 3)
        let fitted = history.fittingPageStates()
        #expect(fitted.entries.map { $0.pageState != nil } == [false, false, true, true, true])
        let encoded = (try? JSONEncoder().encode(fitted))?.count ?? .max
        #expect(encoded <= FrontendBrowserHistory.maxStoredBytes)
        #expect(history.fittingPageStates(maxStoredBytes: 1).entries.allSatisfy { $0.pageState == nil })
    }

    /// The writer saves each entry's page state on this Mac's daemon after a probe found no private
    /// field; a password field, or a remote daemon, saves none.
    @Test func theWriterSavesPageStatesOnlyUnderTheEngineStateRules() async throws {
        let url = try #require(URL(string: "https://example.com/form"))
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: url, origin: .user))
        tab.navigation = BrowserNavigationList(entries: [BrowserNavigationEntry(url: url, title: "Form")], current: 0)
        tab.pageStates = [0: BrowserEntryPageState(url: url, state: "scroll=480;input=typed")]
        tab.evaluationResult = .bool(false)
        let sent = Sent()
        let writer = Self.writer(tab, keepsEngineState: true, sent: sent)
        await writer.flushNow()
        #expect(sent.histories.last?.entries.map(\.pageState) == ["scroll=480;input=typed"])

        tab.evaluationResult = .bool(true)  // the page now shows a password field
        await writer.flushNow()
        writer.cancel()
        #expect(sent.histories.last?.entries.map(\.pageState) == [nil], "a private field keeps page states out")

        tab.evaluationResult = .bool(false)
        let remote = Sent()
        let remoteWriter = Self.writer(tab, keepsEngineState: false, sent: remote)
        await remoteWriter.flushNow()
        remoteWriter.cancel()
        #expect(remote.histories.last?.entries.map(\.pageState) == [nil], "a remote daemon gets none")
    }

    /// A restore takes the entries with their page states only when the record was saved at the
    /// page's address, an entry has one, and none came from a form post.
    @Test func aRestoreTakesTheEntriesOnlyWhenTheyMatchThePage() throws {
        let a = try #require(URL(string: "https://example.com/a")), b = try #require(URL(string: "https://example.com/b"))
        let saved = FrontendBrowserHistory(entries: [.init(url: a.absoluteString, pageState: "sa"),
                                                     .init(url: b.absoluteString, scrollY: 40, pageState: "sb")], index: 1)
        let entries = try #require(BrowserHistoryWriter.restoreEntries(saved, at: b))
        #expect(entries.current == 1 && entries.entries.map(\.pageState) == ["sa", "sb"] && entries.entries[1].scrollY == 40)
        #expect(BrowserHistoryWriter.restoreEntries(saved, at: a) == nil, "saved at another page")
        #expect(BrowserHistoryWriter.restoreEntries(saved.withoutPageStates(), at: b) == nil, "no page state")
        var posted = saved
        posted.entries[0].formPost = true
        #expect(BrowserHistoryWriter.restoreEntries(posted, at: b) == nil, "a form post is never sent again")
    }

    private static func writer(_ tab: MockBrowserTab, keepsEngineState: Bool, sent: Sent) -> BrowserHistoryWriter {
        BrowserHistoryWriter(page: tab, recorded: nil, keepsEngineState: keepsEngineState, delay: .seconds(3600),
                             sleep: { try await Task.sleep(for: $0) }, center: NotificationCenter(),
                             send: { history in sent.histories.append(history); return true })
    }
}
