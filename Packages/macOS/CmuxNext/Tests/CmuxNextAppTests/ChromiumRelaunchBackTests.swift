import CmuxNextBrowser
import CmuxNextBrowserHistory
import CmuxNextDaemon
import Foundation
import Testing

/// Back after a relaunch goes to the real page (audit 4, P7). A Chromium tab whose record has no engine state it
/// may use (a page with a password or file field, a state over the size limit, a form post earlier in its list)
/// came back with one entry, and Back reloaded the saved page from scratch over it. It now gets Chromium's own
/// entries back, by address and title only (fork API 31, `cmux_shim_tab_restore_entries`): no page state, so no
/// form value or chosen file comes back, and nothing is posted again.
@MainActor @Suite struct ChromiumRelaunchBackTests {
    static let a = "https://a.test/", b = "https://b.test/login", c = "https://c.test/"

    static func record(_ urls: [String], index: Int, formPost: Int? = nil, state: Bool = false) -> FrontendBrowserHistory {
        FrontendBrowserHistory(entries: urls.enumerated().map { offset, url in
            FrontendBrowserHistory.Entry(url: url, title: "T\(offset)", formPost: offset == formPost ? true : nil)
        }, index: index, engineState: state ? .init(engine: "chromium-2", data: "opaque") : nil)
    }

    @Test func aRecordWithoutEngineStateRestoresItsEntriesByAddress() throws {
        let entries = try #require(BrowserHistoryWriter.restoreEntries(Self.record([Self.a, Self.b, Self.c], index: 1), at: URL(string: Self.b)!))
        #expect(entries.current == 1)
        #expect(entries.entries.map(\.url.absoluteString) == [Self.a, Self.b, Self.c])
        #expect(entries.entries.map(\.title) == ["T0", "T1", "T2"])
    }

    /// The engine's own state keeps the scroll and form state: it wins where it is usable.
    @Test func usableEngineStateIsNotReplaced() {
        #expect(BrowserHistoryWriter.restoreEntries(Self.record([Self.a, Self.b], index: 1, state: true), at: URL(string: Self.b)!) == nil)
    }

    /// One entry has no Back to give; another page shown than the saved one keeps its own load.
    @Test func nothingToGiveOrAnotherPage() {
        #expect(BrowserHistoryWriter.restoreEntries(Self.record([Self.b], index: 0), at: URL(string: Self.b)!) == nil)
        #expect(BrowserHistoryWriter.restoreEntries(Self.record([Self.a, Self.b], index: 1), at: URL(string: Self.c)!) == nil)
    }

    /// A form result is never posted again: the page shown is not one, and an earlier one comes back as its address (GET).
    @Test func aFormResultShownIsLeftToItsOwnLoad() {
        #expect(BrowserHistoryWriter.restoreEntries(Self.record([Self.a, Self.b], index: 1, formPost: 1), at: URL(string: Self.b)!) == nil)
        #expect(BrowserHistoryWriter.restoreEntries(Self.record([Self.a, Self.b, Self.c], index: 2, formPost: 1), at: URL(string: Self.c)!)?
            .entries.count == 3)
    }

    /// Only web pages come back as entries; a local file or another scheme is left out, as the saved-entry replay does.
    @Test func onlyWebPagesComeBack() throws {
        let entries = try #require(BrowserHistoryWriter.restoreEntries(
            Self.record(["file:///Users/me/secret.html", "about:blank", Self.a, Self.b], index: 3), at: URL(string: Self.b)!))
        #expect(entries.entries.map(\.url.absoluteString) == [Self.a, Self.b])
        #expect(entries.current == 1)
    }
}
