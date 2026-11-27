import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileBrowserStream

/// transport-verify-20261019.md defect 7: after a redial (transport switch,
/// cmux-mobile-host restart) only the shown tab opens again, tabs the Mac no longer
/// lists are dropped, the shown tab tells the Mac it is shown (so it takes
/// the media lane back), and a page the Mac stopped comes back instead of
/// freezing.
final class FakeOpener: BrowserStreamOpening, @unchecked Sendable {
    let lock = NSLock()
    private(set) var opens: [(tab: String, url: String?)] = []
    private var sinks: [String: any BrowserStreamSink] = [:]
    private var streams: [String: FakeStream] = [:]

    func openBrowser(tab: String, url: String?, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection {
        let stream = FakeStream()
        lock.withLock {
            opens.append((tab, url))
            sinks[tab] = sink
            streams[tab] = stream
        }
        return stream
    }

    var tabs: [String] { lock.withLock { opens.map(\.tab) } }
    func sink(_ tab: String) -> (any BrowserStreamSink)? { lock.withLock { sinks[tab] } }
    func stream(_ tab: String) -> FakeStream? { lock.withLock { streams[tab] } }
}

@MainActor @Suite struct RedialTests {
    func settle() async { for _ in 0..<40 { await Task.yield() } }

    func until(_ check: () -> Bool) async {
        for _ in 0..<200 where !check() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A tab shown and laid out, its stream welcomed.
    func show(_ model: StreamedBrowserModel, on opener: FakeOpener) async {
        model.setVisible(true)
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        model.reconnect()
        await until { opener.sink(model.tab) != nil }
        opener.sink(model.tab)?.browserMessage(Data(#"{"t":"welcome","caps":[]}"#.utf8))
        await settle()
    }

    func dropLink(_ opener: FakeOpener, _ tabs: [String]) async {
        for tab in tabs { opener.sink(tab)?.browserClosed(code: "link_closed", reason: "") }
        await settle()
    }

    @Test func onlyTheShownTabOpensAgainOnANewLink() async throws {
        let directory = StreamedBrowserDirectory()
        let first = FakeOpener()
        directory.opener = { first }
        let a = try #require(directory.model(tab: "s1", url: URL(string: "https://example.com/a")))
        let b = try #require(directory.model(tab: "s2", url: URL(string: "https://example.com/b")))
        await show(a, on: first)
        a.setVisible(false)
        await show(b, on: first)
        #expect(first.tabs == ["s1", "s2"])
        first.sink("s2")?.browserMessage(Data(#"{"t":"rb.page","url":"https://example.org/moved","title":"M","loading":false,"can_go_back":true,"can_go_forward":false}"#.utf8))
        await settle()
        await dropLink(first, ["s1", "s2"])

        let second = FakeOpener()
        directory.opener = { second }
        directory.linkChanged()
        await until { !second.tabs.isEmpty }
        await settle()
        #expect(second.tabs == ["s2"], "only the shown tab opens on the new link")
        // A restarted cmux-mobile-host starts the page where it was.
        #expect(second.lock.withLock { second.opens.first?.url } == "https://example.org/moved")

        // The hidden one opens when it is shown again.
        b.setVisible(false)
        a.setVisible(true)
        await until { second.tabs.count == 2 }
        #expect(second.tabs == ["s2", "s1"])
    }

    /// A link that came up while the app was in the background opens the
    /// shown tab when the app comes back.
    @Test func theShownTabOpensWhenTheAppComesBack() async throws {
        let directory = StreamedBrowserDirectory()
        let first = FakeOpener()
        directory.opener = { first }
        let a = try #require(directory.model(tab: "s1", url: nil))
        await show(a, on: first)
        directory.setAppActive(false)
        await dropLink(first, ["s1"])
        let second = FakeOpener()
        directory.opener = { second }
        directory.linkChanged()
        await settle()
        #expect(second.tabs.isEmpty)
        directory.setAppActive(true)
        await until { second.tabs == ["s1"] }
        #expect(second.tabs == ["s1"])
    }

    /// Live check (switch row): a browser workspace made on the phone opens
    /// its page under the placeholder tab id; the Mac's real tab id must take
    /// it over, or the redial reopens a new blank host for the real id.
    @Test func aPlaceholderTabsPageMovesToTheRealTab() async throws {
        let directory = StreamedBrowserDirectory()
        let first = FakeOpener()
        directory.opener = { first }
        let page = try #require(directory.model(tab: "new-ab12-t1", url: nil))
        await show(page, on: first)
        first.sink("new-ab12-t1")?.browserMessage(Data(#"{"t":"rb.page","url":"https://example.org/typed","title":"T","loading":false,"can_go_back":true,"can_go_forward":false}"#.utf8))
        await settle()
        directory.rename(tab: "new-ab12-t1", to: "s108")
        #expect(directory.model(tab: "s108", url: nil) === page)
        #expect(first.stream("new-ab12-t1")?.closed == false, "the open stream keeps going")
        directory.retain(tabs: ["s108"])
        await dropLink(first, ["new-ab12-t1"])
        let second = FakeOpener()
        directory.opener = { second }
        directory.linkChanged()
        await until { !second.tabs.isEmpty }
        // The same Mac host (its key stays the placeholder's): the page, history and all.
        #expect(second.tabs == ["new-ab12-t1"])
    }

    @Test func tabsTheMacNoLongerListsAreDropped() async throws {
        let directory = StreamedBrowserDirectory()
        let first = FakeOpener()
        directory.opener = { first }
        let a = try #require(directory.model(tab: "s1", url: nil))
        let b = try #require(directory.model(tab: "s2", url: nil))
        await show(a, on: first)
        await show(b, on: first)
        // s1's workspace closed on the Mac.
        directory.retain(tabs: ["s2"])
        #expect(first.stream("s1")?.closed == true)
        #expect(first.stream("s2")?.closed == false)
        await dropLink(first, ["s1", "s2"])

        let second = FakeOpener()
        directory.opener = { second }
        directory.linkChanged()
        await until { !second.tabs.isEmpty }
        await settle()
        #expect(second.tabs == ["s2"])
        #expect(directory.model(tab: "s1", url: nil) !== a, "a dropped tab starts over")
    }

    @Test func theShownStateReachesTheMac() async throws {
        let opener = FakeOpener()
        let model = StreamedBrowserModel(tab: "s1", url: nil) { sink in
            try await opener.openBrowser(tab: "s1", url: nil, sink: sink)
        }
        await show(model, on: opener)
        let stream = try #require(opener.stream("s1"))
        #expect(stream.sent == ["rb.open", "rb.visibility"], "a new viewer says it is shown (the host keeps the last one's state)")
        model.setVisible(false)
        model.setVisible(true)
        #expect(stream.sent == ["rb.open", "rb.visibility", "rb.visibility", "rb.visibility"])
        #expect(stream.lock.withLock { stream.messages.compactMap { $0["visible"] as? Bool } } == [true, false, true])
    }

    /// Review finding 3: a hidden page never opens by itself (an open takes
    /// the lane); one hidden while its open was on the way says so after its
    /// `rb.open`, and the shown tab tells the Mac again that it is shown.
    @Test func aHiddenPageNeverOpensAndALateHiddenOpenGivesTheLaneBack() async throws {
        let directory = StreamedBrowserDirectory()
        let opener = FakeOpener()
        directory.opener = { opener }
        let a = try #require(directory.model(tab: "s1", url: nil))
        await show(a, on: opener)
        let b = try #require(directory.model(tab: "s2", url: nil))
        b.setVisible(false)
        b.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        await settle()
        #expect(opener.tabs == ["s1"], "a hidden page does not open on layout")
        // Shown, then hidden again before its stream's welcome.
        a.setVisible(false)
        b.setVisible(true)
        b.setVisible(false)
        a.setVisible(true)
        await until { opener.sink("s2") != nil }
        let shown = try #require(opener.stream("s1"))
        func shownSaid() -> Int { shown.lock.withLock { shown.messages.filter { $0["visible"] as? Bool == true }.count } }
        let before = shownSaid()
        opener.sink("s2")?.browserMessage(Data(#"{"t":"welcome","caps":[]}"#.utf8))
        await settle()
        #expect(opener.stream("s2")?.sent == ["rb.open", "rb.visibility"])
        #expect(shownSaid() == before + 1, "the shown tab claims the lane again")
    }

    @Test func aShownPageTheMacStoppedOpensAgainAtItsAddress() async throws {
        let directory = StreamedBrowserDirectory()
        let opener = FakeOpener()
        directory.opener = { opener }
        let model = try #require(directory.model(tab: "s1", url: URL(string: "https://example.com/a")))
        await show(model, on: opener)
        opener.sink("s1")?.browserMessage(Data(#"{"t":"rb.page","url":"https://example.org/b","title":"B","loading":false,"can_go_back":true,"can_go_forward":false}"#.utf8))
        await settle()
        // The host limit stopped this tab's page.
        opener.sink("s1")?.browserClosed(code: "evicted", reason: "the Mac stopped this page")
        await until { opener.tabs.count == 2 }
        #expect(opener.tabs == ["s1", "s1"])
        #expect(opener.lock.withLock { opener.opens.last?.url } == "https://example.org/b", "reloads where it was")
    }

    @Test func aHiddenPageTheMacStoppedOpensWhenShown() async throws {
        let directory = StreamedBrowserDirectory()
        let opener = FakeOpener()
        directory.opener = { opener }
        let model = try #require(directory.model(tab: "s1", url: nil))
        await show(model, on: opener)
        model.setVisible(false)
        opener.sink("s1")?.browserClosed(code: "evicted", reason: "")
        await settle()
        #expect(opener.tabs == ["s1"])
        model.setVisible(true)
        await until { opener.tabs.count == 2 }
        #expect(opener.tabs == ["s1", "s1"])
    }

    @Test func aPageStoppedOverAndOverStopsTryingAndOffersReopen() async throws {
        let directory = StreamedBrowserDirectory()
        let opener = FakeOpener()
        directory.opener = { opener }
        let model = try #require(directory.model(tab: "s1", url: nil))
        await show(model, on: opener)
        for attempt in 2...4 {
            opener.sink("s1")?.browserClosed(code: "evicted", reason: "")
            await until { opener.tabs.count == min(attempt, 3) }
            await settle()
        }
        #expect(opener.tabs.count == 3, "two reopens without a frame, then it waits")
        guard case .waiting = model.phase else { Issue.record("expected waiting, got \(model.phase)"); return }
        #expect(model.canReopen)
        model.reopen()
        await until { opener.tabs.count == 4 }
        #expect(opener.tabs.count == 4)
    }

    @Test func aPageAnotherViewerTookWaitsWithAWayBack() async throws {
        let directory = StreamedBrowserDirectory()
        let opener = FakeOpener()
        directory.opener = { opener }
        let model = try #require(directory.model(tab: "s1", url: nil))
        await show(model, on: opener)
        opener.sink("s1")?.browserClosed(code: "replaced", reason: "another viewer opened this tab")
        await settle()
        #expect(opener.tabs == ["s1"], "never fights another viewer by itself")
        #expect(model.canReopen)
        model.reopen()
        await until { opener.tabs.count == 2 }
        #expect(opener.tabs == ["s1", "s1"])
    }
}
