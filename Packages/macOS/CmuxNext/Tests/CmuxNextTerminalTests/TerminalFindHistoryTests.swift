import AppKit
import CmuxNextTerminalFind
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Cmd-F over the daemon's whole history: a match only in scrollback, far past the screen, is found
/// and scrolled to and selected. The daemon's matching is Rust's (`terminal-find`); these hold the
/// bar's side: paging, the count, stepping and the reveal in Ghostty's own rows.
@MainActor @Suite(.serialized, .closesItsWindows)
struct TerminalFindHistoryTests {
    /// A history that answers from a script, newest page first.
    final class ScriptedHistory: TerminalFindHistory {
        var pages: [TerminalFindPage]
        var requests: [TerminalFindPageRequest] = []

        init(pages: [TerminalFindPage]) { self.pages = pages }

        func page(_ request: TerminalFindPageRequest) async throws -> TerminalFindPage {
            requests.append(request)
            return pages.isEmpty ? TerminalFindPage(matches: [], nextBefore: nil, epoch: 1, columns: 80) : pages.removeFirst()
        }
    }

    final class FakeTarget: TerminalFindTarget {
        let history: ScriptedHistory
        var revealed: [TerminalFindMatch] = []
        init(history: ScriptedHistory) { self.history = history }
        var historyFind: (any TerminalFindHistory)? { history }
        func revealHistoryMatch(_ match: TerminalFindMatch, columns: Int) -> Bool { revealed.append(match); return true }
        func setSearchNeedle(_ needle: String) {}
        func navigateSearch(_ direction: TerminalFindDirection) {}
        func endSearch() {}
        func clearSelection() {}
        var isSelectionPinned: Bool { false }
        func focusTerminal() {}
        func showFindBar() {}
    }

    static func match(_ marker: UInt64, fromBottom: Int) -> TerminalFindMatch {
        TerminalFindMatch(startMarker: marker, startColumn: 0, endMarker: marker, endColumn: 5, rowsFromBottom: fromBottom, text: "needle")
    }

    static func until(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func pagesStreamIntoOneCountAndTheFirstMatchIsRevealed() async {
        let history = ScriptedHistory(pages: [
            TerminalFindPage(matches: [Self.match(9000, fromBottom: 20)], nextBefore: 500, epoch: 3, columns: 80),
            TerminalFindPage(matches: [Self.match(40, fromBottom: 8960)], nextBefore: nil, epoch: 3, columns: 80),
        ])
        let target = FakeTarget(history: history)
        let find = TerminalFindController(target: target)
        find.open()
        find.updateQuery("needle")
        await Self.until { !find.isSearching && find.total == 2 }
        #expect(find.count == .position(1, of: 2))
        #expect(target.revealed.first?.rowsFromBottom == 20)
        #expect(history.requests.count == 2 && history.requests[1].before == 500 && history.requests[1].epoch == 3,
                "the second page did not continue from the first's cursor")
        find.navigate(.next)
        #expect(target.revealed.last?.rowsFromBottom == 8960, "stepping did not reach the match in far scrollback")
        #expect(find.count == .position(2, of: 2))
    }

    @Test func anInvalidRegexIsShownInline() async {
        let history = ScriptedHistory(pages: [
            TerminalFindPage(matches: [], nextBefore: nil, epoch: 1, invalidPattern: "unclosed group", columns: 80),
        ])
        let target = FakeTarget(history: history) // the controller holds its target weakly
        let find = TerminalFindController(target: target)
        find.open()
        find.setOption(\.regex, true)
        find.updateQuery("(")
        await Self.until { find.invalidPattern != nil }
        #expect(find.count == .invalidPattern("unclosed group"))
        #expect(history.requests.first?.options.regex == true)
        withExtendedLifetime(target) {}
    }

    /// The live case: 150 lines of output, "needle" on the sixth, far above the screen. The history
    /// reports it by rows from the bottom; the surface must scroll to it and select its text.
    @Test func aMatchOnlyInScrollbackIsScrolledToAndSelected() async throws {
        let harness = try TerminalFindOpenFocusTests.harness()
        defer { harness.close() }
        let terminal = harness.terminals[0], session = terminal.session
        var text = ""
        for line in 0..<150 { text += line == 5 ? "line 5 needle here\r\n" : "line \(line)\r\n" }
        terminal.io.send(.output(Data(text.utf8)))
        await Self.until { (session.togglePlaceViewport()?.total ?? 0) >= 150 }
        let viewport = try #require(session.togglePlaceViewport(), "Ghostty reported no scrollbar")
        let screenTop = viewport.top
        let hit = TerminalFindMatch(startMarker: 5, startColumn: 7, endMarker: 5, endColumn: 12,
                                    rowsFromBottom: viewport.total - 5, text: "needle")
        session.historyFind = ScriptedHistory(pages: [TerminalFindPage(matches: [hit], nextBefore: nil, epoch: 1, columns: 80)])
        session.find.open()
        session.find.updateQuery("needle")
        await Self.until { session.find.total == 1 }
        #expect(session.find.count == .position(1, of: 1))
        #expect(TerminalSelection.read(session.surfaceView.surface)?.text == "needle", "the match was not selected")
        // Ghostty reports the scrolled viewport on a later main-actor pass.
        await Self.until { (session.togglePlaceViewport()?.top ?? screenTop) < screenTop }
        let top = try #require(session.togglePlaceViewport()).top
        #expect(top < screenTop && top <= 5, "the view did not scroll up to the match (top \(top), was \(screenTop))")
    }
}
