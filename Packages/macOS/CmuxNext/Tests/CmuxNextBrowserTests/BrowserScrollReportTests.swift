@testable import CmuxNextBrowser
import Foundation
import Testing

/// A page's scroll used to be measured only when the person left the app or at quit (within
/// 400 ms), so a crash, or a quit whose measure ran out, reopened the page at the top (restore
/// journey on a capture slot, crash and update variants: `page[tall].scrollY` 1500 -> 0). The
/// page now reports where its scrolling settled (``BrowserScrollReportScript``), and the saved
/// history carries it without asking the page again.
@MainActor
@Suite struct BrowserScrollReportTests {
    static let tall = URL(string: "http://127.0.0.1:8000/tall")!
    static let other = URL(string: "http://127.0.0.1:8000/other")!

    @Test func aSettledScrollIsTheShownPagesReport() {
        var machine = Self.loaded(Self.tall)
        machine.apply(.pageScrolled(1500))
        #expect(machine.state.scrollReport == BrowserScrollReport(url: Self.tall, y: 1500))
    }

    @Test func theSavedHistoryCarriesTheReportedScrollWithoutMeasuring() async throws {
        var machine = Self.loaded(Self.tall)
        machine.apply(.pageScrolled(1500))
        let host = Host(state: machine.state)
        let session = BrowserRestoredSession { host }
        let saved = try #require(await session.savedSession(measuringScroll: false))
        #expect(saved.entries[saved.current].scrollY == 1500, "a crash now would reopen the page at the top")
        #expect(host.measured == 0, "the page was asked again")
    }

    @Test func anotherPagesReportIsNotTheShownPages() async throws {
        var machine = Self.loaded(Self.tall)
        machine.apply(.pageScrolled(1500))
        machine.apply(.urlChanged(Self.other))
        let session = BrowserRestoredSession { Host(state: machine.state) }
        let saved = try #require(await session.savedSession(measuringScroll: false))
        #expect(saved.entries[saved.current].url == Self.other)
        #expect(saved.entries[saved.current].scrollY == nil)
    }

    /// Review of #22919 at ce9cd46, note 3, and at 6f77b0a, note 2: a quit's late browser-records
    /// save can read a page whose engine already closed it. A closed page has no back/forward list,
    /// so its session would keep only the shown page and replace the good record the daemon holds
    /// (written after each navigation). A closed page has no session to save.
    @Test func aClosedPageHasNoSessionToSave() async throws {
        var machine = Self.loaded(Self.tall)
        machine.apply(.pageScrolled(1500))
        let host = Host(state: machine.state)
        let session = BrowserRestoredSession { host }
        #expect(await session.savedSession(measuringScroll: false) != nil, "a live page had no session")
        host.closed = true
        #expect(await session.savedSession(measuringScroll: true) == nil, "a closed page's session would replace its good record")
        #expect(await session.savedSession(measuringScroll: false) == nil)
        #expect(host.measured == 0, "a closed page was asked for its scroll")
    }

    /// Review of #22919 at c99b21a, finding 1: the engine can close the page while the save asks it
    /// for its scroll (a quit's engine stop ends the pending page question at once). The tab was
    /// open when the save began, but its back/forward list is gone when the save reads it, so the
    /// session must not be written over the good record either.
    @Test func aPageClosedWhileItIsMeasuredHasNoSessionToSave() async throws {
        let machine = Self.loaded(Self.tall)
        let host = Host(state: machine.state)
        host.closesWhenMeasured = true
        let session = BrowserRestoredSession { host }
        #expect(await session.savedSession(measuringScroll: true) == nil,
                "a page closed during its scroll measure gave a session that would replace its good record")
        #expect(host.measured == 1)
    }

    @Test(arguments: ["1500", " 12.6 "]) func aReportPayloadIsAPosition(_ payload: String) {
        #expect(BrowserScrollReport.y(fromPayload: payload) == Double(payload.trimmingCharacters(in: .whitespaces))?.rounded())
    }

    @Test(arguments: ["", "-1", "nan", "inf", "1e9", "{}"]) func anUntrustedPayloadIsNoPosition(_ payload: String) {
        #expect(BrowserScrollReport.y(fromPayload: payload) == nil)
    }

    private static func loaded(_ url: URL) -> BrowserTabStateMachine {
        var machine = BrowserTabStateMachine()
        let id = BrowserNavigationID(rawValue: 1)
        machine.apply(.started(id, url: url))
        machine.apply(.committed(id, url: url))
        machine.apply(.finished(id))
        return machine
    }

    /// A tab that shows `state` and counts how often its page is asked for its scroll.
    private final class Host: BrowserRestoredSessionHost {
        let state: BrowserTabState
        var measured = 0
        var closed = false
        /// The engine closes the page while it answers the scroll question.
        var closesWhenMeasured = false
        init(state: BrowserTabState) { self.state = state }
        var isClosed: Bool { closed }
        var nativeHistory: (back: Bool, forward: Bool) { (false, false) }
        func nativeNavigationList() -> BrowserNavigationList? { nil }
        func goToNativeEntry(offset: Int) -> Bool { false }
        func applyHistoryAvailability(canGoBack: Bool, canGoForward: Bool) {}
        func currentScrollY() async -> Double? {
            measured += 1
            if closesWhenMeasured { closed = true }
            return nil
        }
        func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue { .null }
        func load(_ url: URL) {}
    }
}
