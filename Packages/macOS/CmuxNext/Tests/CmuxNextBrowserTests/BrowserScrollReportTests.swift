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
        init(state: BrowserTabState) { self.state = state }
        var isClosed: Bool { false }
        var nativeHistory: (back: Bool, forward: Bool) { (false, false) }
        func nativeNavigationList() -> BrowserNavigationList? { nil }
        func goToNativeEntry(offset: Int) -> Bool { false }
        func applyHistoryAvailability(canGoBack: Bool, canGoForward: Bool) {}
        func currentScrollY() async -> Double? {
            measured += 1
            return nil
        }
        func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue { .null }
        func load(_ url: URL) {}
    }
}
