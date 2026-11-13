#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Live report (2026-11-12, iPhone simulator): a second device set the
/// shared grid to 30×12 under Fit the smallest viewer, smaller than the
/// phone's 53×40. A shell and procps `top` (primary screen) showed the 12
/// rows at the bottom of the page, on the composer, with no letterbox and no
/// "30×12 · set by Rig Mac" note (docs/shared-terminal-sizing.md "Showing
/// the bounds"; PROTOCOL.md "A grid larger than the phone").
///
/// - The note was a subview of the TUI host and shown only on the alternate screen.
/// - A change of the Mac's rows alone never re-ran the layout.
/// - The row shift's offset read the session's rows as parsed, not as of the
///   bytes being fed.
///
/// Through the real screen (`TerminalViewController`) and Ghostty surface.
@MainActor
@Suite(.serialized) struct TerminalHostGridNoteTests {
    /// A Mac terminal whose grid another device set.
    @MainActor
    final class GridSession: TerminalSession {
        let programName = "zsh"
        var isAlternateScreen = false
        var remoteColumns: Int? = 30
        var remoteRows: Int? = 12
        private(set) var handler: (@MainActor (TerminalSessionEvent) -> Void)?

        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) { self.handler = handler }
        func send(_ bytes: Data) {}
        /// The phone's own grid, as the screen last sent it.
        private(set) var sent: (columns: Int, rows: Int)?
        func resize(columns: Int, rows: Int) { sent = (columns, rows) }
        func stop() {}

        func emit(_ event: TerminalSessionEvent) { handler?(event) }
        func write(_ text: String) { handler?(.output(Data(text.utf8))) }
    }

    @MainActor
    struct Screen {
        let screen: TerminalViewController
        let session: GridSession
        let window: UIWindow

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }

        /// The page's scroll view (the primary screen's rows).
        var scrollView: UIScrollView? {
            screen.view.subviews.first { $0 is TerminalScrollView } as? UIScrollView
        }

        /// The top of the terminal area in the page: the primary screen's top inset.
        var terminalTop: CGFloat? {
            scrollView.map { $0.frame.minY + $0.contentInset.top }
        }

        /// A label showing `text` that the person can see (it and every
        /// view above it shown, inside the window).
        func visibleLabel(_ text: String) -> UILabel? {
            func search(_ view: UIView) -> UILabel? {
                if let label = view as? UILabel, label.text == text, Self.isShown(label, in: window) { return label }
                for sub in view.subviews { if let found = search(sub) { return found } }
                return nil
            }
            return search(screen.view)
        }

        static func isShown(_ view: UIView, in window: UIWindow) -> Bool {
            var current: UIView? = view
            while let each = current {
                if each.isHidden || each.alpha < 0.01 { return false }
                current = each.superview
            }
            let frame = view.convert(view.bounds, to: window)
            return !frame.isEmpty && window.bounds.intersects(frame)
        }
    }

    static func makeScreen() async throws -> Screen {
        let session = GridSession()
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "host grid")
        let screen = TerminalViewController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        try await TerminalPredictionInputTests.waitUntil(5) { session.handler != nil && screen.surface.surface != nil }
        try #require(session.handler != nil, "the screen never started its session")
        return Screen(screen: screen, session: session, window: window)
    }

    /// History above a 30×12 screen, then the screen drawn by cursor address
    /// (as `top` paints it) with the cursor on its first row.
    static func primaryPaint(rows: Int) -> String {
        var text = "\u{1B}c"
        for line in 1...60 { text += "history \(line)\r\n" }
        for row in 1...rows { text += "\u{1B}[\(row);1H\u{1B}[2Krow \(row)" }
        return text + "\u{1B}[1;1H"
    }

    @Test func aShorterGridOnThePrimaryScreenIsPinnedToTheTopWithTheNote() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let rig = try await Self.makeScreen()
        defer { rig.close() }
        rig.session.emit(.hostGrid(columns: 30, rows: 12))
        rig.session.emit(.hostGridOwner("Rig Mac"))
        rig.session.write(Self.primaryPaint(rows: 12))

        let note = "30×12 · set by Rig Mac"
        let top = try #require(rig.terminalTop)
        // The Mac's first row (the cursor's) rests at the top of the terminal area.
        func firstRowY() -> CGFloat? {
            rig.screen.surface.visibleCursorCell.map { rig.screen.surface.convert($0, to: rig.screen.view).minY }
        }
        try await TerminalPredictionInputTests.waitUntil(5) {
            rig.visibleLabel(note) != nil && firstRowY().map { abs($0 - top) < 1 } == true
        }
        #expect(rig.visibleLabel(note) != nil, "no visible \"\(note)\" note")
        let cell = rig.screen.surface.cellSize.height
        let rowY = try #require(firstRowY(), "the cursor (the Mac's first row) is not on screen")
        #expect(abs(rowY - top) < 1, "the Mac's first row is at \(rowY), the terminal area starts at \(top) (cell \(cell))")
        if let label = rig.visibleLabel(note) {
            // In the letterbox: below the Mac's 12 rows, over no text.
            #expect(label.frame.minY >= top + 12 * cell - 0.5, "the note overlaps the grid (\(label.frame), rows end at \(top + 12 * cell))")
            #expect(label.accessibilityLabel == note)
        }
    }

    /// A fresh attach with no history and the Mac's first rows blank: the
    /// grid still starts at its first row, not at its first row with text.
    @Test func blankRowsAtTheGridsTopStayInIt() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let rig = try await Self.makeScreen()
        defer { rig.close() }
        rig.session.emit(.hostGrid(columns: 30, rows: 12))
        rig.session.emit(.hostGridOwner("Rig Mac"))
        var paint = "\u{1B}c"
        for row in 4...12 { paint += "\u{1B}[\(row);1Hrow \(row)" }
        rig.session.write(paint + "\u{1B}[1;1H")
        let top = try #require(rig.terminalTop)
        func firstRowY() -> CGFloat? {
            rig.screen.surface.visibleCursorCell.map { rig.screen.surface.convert($0, to: rig.screen.view).minY }
        }
        try await TerminalPredictionInputTests.waitUntil(5) {
            rig.visibleLabel("30×12 · set by Rig Mac") != nil && firstRowY().map { abs($0 - top) < 1 } == true
        }
        let rowY = try #require(firstRowY(), "the cursor (the Mac's first row) is not on screen")
        #expect(abs(rowY - top) < 1, "the Mac's blank first row is at \(rowY), the terminal area starts at \(top)")
    }

    /// The owner changes: the note names the new one. The grid goes back to
    /// the phone's own: the note goes and the last row rests on the composer
    /// again (the pin's bottom inset is dropped).
    @Test func theNoteFollowsTheOwnerAndGoesWithThePhonesOwnGrid() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let rig = try await Self.makeScreen()
        defer { rig.close() }
        rig.session.emit(.hostGrid(columns: 30, rows: 12))
        rig.session.emit(.hostGridOwner("Rig Mac"))
        rig.session.write(Self.primaryPaint(rows: 12))
        try await TerminalPredictionInputTests.waitUntil(5) { rig.visibleLabel("30×12 · set by Rig Mac") != nil }
        let scroll = try #require(rig.scrollView)
        let pinnedInset = scroll.contentInset.bottom

        rig.session.emit(.hostGridOwner("Other iPhone"))
        #expect(rig.visibleLabel("30×12 · set by Other iPhone") != nil, "the note did not follow the owner")

        let own = try #require(rig.session.sent, "the screen never sent its grid")
        rig.session.remoteColumns = own.columns
        rig.session.remoteRows = own.rows
        rig.session.emit(.hostGridOwner(nil))
        rig.session.emit(.hostGrid(columns: own.columns, rows: own.rows))
        rig.session.write("\u{1B}[\(own.rows);1H$ ")
        try await TerminalPredictionInputTests.waitUntil(3) { scroll.contentInset.bottom < pinnedInset - 1 }
        #expect(scroll.contentInset.bottom < pinnedInset - 1, "the pin's inset stayed (\(scroll.contentInset.bottom) vs \(pinnedInset))")
        #expect(rig.screen.view.subviews.compactMap { $0 as? UILabel }.allSatisfy { $0.isHidden || $0.accessibilityIdentifier != "terminal.hostGridNote" },
                "the note stayed with the phone's own grid")
    }

    @Test func aRowsOnlyGridChangeInATUIShowsTheNote() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let rig = try await Self.makeScreen()
        defer { rig.close() }
        let columns = rig.screen.hostLayout.phoneColumns
        try #require(columns > 0, "the page has no columns yet")
        rig.session.remoteColumns = columns
        // A grid shorter than the page already (its note shows), so no
        // row shift or pan lays the TUI out again by itself.
        rig.session.remoteRows = 20
        rig.session.emit(.hostGrid(columns: columns, rows: 20))
        rig.session.emit(.hostGridOwner("Rig Mac"))
        rig.session.isAlternateScreen = true
        rig.session.emit(.alternateScreen(true))
        rig.session.write("\u{1B}[?1049h\u{1B}[H\u{1B}[2Jtop")
        try await TerminalPredictionInputTests.waitUntil(5) { rig.screen.model.isTUI }
        try #require(rig.screen.model.isTUI)

        // Only the Mac's rows change (the width stays the phone's).
        rig.session.remoteRows = 12
        rig.session.emit(.hostGrid(columns: columns, rows: 12))
        rig.session.write("\u{1B}[H\u{1B}[2Jtop at 12 rows")
        let note = "\(columns)×12 · set by Rig Mac"
        try await TerminalPredictionInputTests.waitUntil(3) { rig.visibleLabel(note) != nil }
        #expect(rig.visibleLabel(note) != nil, "no visible \"\(note)\" note after a rows-only change")
    }

    @Test func bytesQueuedBeforeAResizeUseTheRowsTheyWereSentFor() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let rig = try await Self.makeScreen()
        defer { rig.close() }
        rig.session.emit(.hostGrid(columns: 30, rows: 12))
        rig.session.write("\u{1B}c$ ")
        try await TerminalPredictionInputTests.waitUntil(2) { (rig.screen.surface.activeAreaText() ?? "").contains("$") }

        // In one turn: a batch goes to Ghostty, the next waits behind it,
        // and the Mac's grid changes (the session's rows update when the
        // event is parsed, ahead of the queued bytes).
        rig.session.write("\u{1B}[5;1Hfirst")
        rig.session.write("\u{1B}[1;1HQUEUED")
        rig.session.remoteRows = 20
        rig.session.emit(.hostGrid(columns: 30, rows: 20))
        rig.session.write("\u{1B}[2;1HAFTER")

        func rowOf(_ word: String) -> Int? {
            let lines = (rig.screen.surface.activeAreaText() ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            return lines.firstIndex { $0.contains(word) }
        }
        try await TerminalPredictionInputTests.waitUntil(3) { rowOf("AFTER") != nil && rowOf("QUEUED") != nil }
        let gridRows = rig.screen.surface.grid.rows
        let queued = try #require(rowOf("QUEUED"), "the queued bytes were not drawn")
        // Sent for the 12-row grid: the Mac's row 1 is the mirror's row `rows - 12`.
        #expect(queued == gridRows - 12, "queued bytes landed on mirror row \(queued) (12-row grid: \(gridRows - 12), 20-row grid: \(gridRows - 20))")
        let after = try #require(rowOf("AFTER"))
        #expect(after == gridRows - 20 + 1, "bytes after the resize use the 20-row grid")
    }
}
#endif
