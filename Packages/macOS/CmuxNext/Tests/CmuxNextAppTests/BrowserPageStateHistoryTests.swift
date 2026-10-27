import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextBrowserHistory
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextInput
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

    /// The fit adds up each state's encoded bytes instead of encoding the history once per dropped
    /// entry: the cost is what the state adds to the encoded record, escapes and all.
    @Test func aPageStatesCostIsTheBytesItAddsToTheRecord() throws {
        let bare = FrontendBrowserHistory(entries: [.init(url: "https://example.com/")], index: 0)
        let bareBytes = try JSONEncoder().encode(bare).count
        for state in ["AA/+==", "a\"b\\c\nd\t\u{1}é", ""] {
            var with = bare
            with.entries[0].pageState = state
            let added = try JSONEncoder().encode(with).count - bareBytes
            #expect(FrontendBrowserHistory.encodedCost(ofPageState: state) == added, "\(state.debugDescription)")
        }
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

    /// A probe that does not answer after a scroll or a form edit alone (only the page states
    /// changed) writes nothing: the record the daemon holds stays, page states and all.
    @Test func aFailedProbeAfterAPageStateChangeKeepsTheRecord() async throws {
        let url = try #require(URL(string: "https://example.com/form"))
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: url, origin: .user))
        tab.navigation = BrowserNavigationList(entries: [BrowserNavigationEntry(url: url, title: "Form")], current: 0)
        tab.pageStates = [0: BrowserEntryPageState(url: url, state: "scroll=0;input=")]
        tab.evaluationResult = .bool(false)
        let sent = Sent()
        let writer = Self.writer(tab, keepsEngineState: true, sent: sent)
        await writer.flushNow()
        #expect(sent.histories.map { $0.entries.map(\.pageState) } == [["scroll=0;input="]])

        tab.pageStates = [0: BrowserEntryPageState(url: url, state: "scroll=480;input=typed")]
        tab.evaluationResult = .null  // the isolated-world probe did not answer
        await writer.flushNow()
        writer.cancel()
        #expect(sent.histories.count == 1, "a failed probe sends no history without the kept states")
    }

    /// A tab whose writer started on this Mac's daemon and that later moved to a remote machine
    /// sends that machine no page state, as no engine state.
    @Test func aTabMovedToARemoteDaemonSendsItNoPageStates() async throws {
        let url = try #require(URL(string: "https://example.com/form"))
        let page = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: url, origin: .user))
        page.navigation = BrowserNavigationList(entries: [BrowserNavigationEntry(url: url, title: "Form")], current: 0)
        page.pageStates = [0: BrowserEntryPageState(url: url, state: "scroll=480;input=typed")]
        page.evaluationResult = .bool(false)
        let local = DaemonService(), remote = DaemonService(machineID: "remote")
        let chromium = ChromiumEngineSlot(CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap()))
        let service = BrowserTabService(daemon: local, chromium: chromium, mainWork: linklessMainWork())
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .browser, url: url.absoluteString,
                                       browserRenderer: "frontend", browserEngine: "chromium"))
        let moved = Moved()
        let stored = Stored()
        service.daemonForTab = { _ in moved.value ? remote : local }
        service.tabModel = { $0 == tab.id ? tab : nil }
        service.writeBackDelay = .seconds(3600)
        service.update = { _, _, _ in true }
        service.updateState = { _, _, _ in true }
        service.fetchHistory = { _, _ in nil }
        service.storeHistory = { daemon, _, history in
            stored.sends.append((daemon.isLocal, history))
            return true
        }
        service.track(page, for: tab)
        // The writer starts in the turn the daemon's (here immediate) history read resumes.
        for _ in 0 ..< 1000 where service.historyWriters[tab.id] == nil { await Task.yield() }
        try #require(service.historyWriters[tab.id] != nil, "the history writer starts on this Mac's daemon")

        moved.value = true
        await service.flushRecords()
        service.untrack(tab.id)
        let send = try #require(stored.sends.last)
        #expect(!send.local, "the send went to the machine the tab moved to")
        #expect(send.history.entries.allSatisfy { $0.pageState == nil }, "no page_state reaches a remote daemon")
        #expect(send.history.engineState == nil)
    }

    final class Moved {
        var value = false
    }

    final class Stored {
        var sends: [(local: Bool, history: FrontendBrowserHistory)] = []
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
