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

    /// Review of #42422 (finding 1): the owner event came straight to the
    /// note while the grid it set waited behind queued bytes, so for a few
    /// frames the note named the new owner next to the old grid. The owner
    /// now waits its turn in the output queue with the grid.
    @Test func aNewOwnerWaitsForTheGridItSet() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let rig = try await Self.makeScreen()
        defer { rig.close() }
        rig.session.emit(.hostGrid(columns: 30, rows: 12))
        rig.session.emit(.hostGridOwner("Rig Mac"))
        rig.session.write(Self.primaryPaint(rows: 12))
        try await TerminalPredictionInputTests.waitUntil(5) { rig.visibleLabel("30×12 · set by Rig Mac") != nil }
        try #require(rig.visibleLabel("30×12 · set by Rig Mac") != nil)

        // In one turn: bytes for the old grid, then the new grid and its owner.
        rig.session.write("\u{1B}[3;1Hstill the old grid")
        rig.session.remoteColumns = 28
        rig.session.remoteRows = 10
        rig.session.emit(.hostGrid(columns: 28, rows: 10))
        rig.session.emit(.hostGridOwner("Other iPhone"))
        #expect(rig.screen.hostGridOwner == "Rig Mac", "the owner changed ahead of the bytes and the grid before it")
        #expect(rig.visibleLabel("30×12 · set by Other iPhone") == nil, "the note named the new owner next to the old grid")

        try await TerminalPredictionInputTests.waitUntil(5) { rig.visibleLabel("28×10 · set by Other iPhone") != nil }
        #expect(rig.visibleLabel("28×10 · set by Other iPhone") != nil, "the note never showed the new grid and owner")
    }

    /// Review of #42422 (findings 2 and 4): a resize the phone sent is in
    /// flight. The Mac's grid at the phone's old claim or its new one shows
    /// no note (it is the phone's own); but a grid at the old claim that a
    /// named device owns is that device's and shows the note.
    @Test func aResizeInFlightShowsNoNoteUnlessAnotherDeviceOwnsTheGrid() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let rig = try await Self.makeScreen()
        defer { rig.close() }
        try await TerminalPredictionInputTests.waitUntil(5) { rig.session.sent != nil }
        let first = try #require(rig.session.sent, "the screen never sent its grid")
        rig.session.remoteColumns = first.columns
        rig.session.remoteRows = first.rows
        rig.session.emit(.hostGrid(columns: first.columns, rows: first.rows))
        rig.session.write("\u{1B}c$ ")

        // The phone's page gets narrower: it sends a new grid.
        rig.window.frame = CGRect(x: 0, y: 0, width: 320, height: 844)
        rig.window.layoutIfNeeded()
        try await TerminalPredictionInputTests.waitUntil(5) { rig.session.sent.map { $0 != first } == true }
        let second = try #require(rig.session.sent, "the screen never sent a grid")
        try #require(second != first, "the screen never sent its new grid")
        func noteShown() -> Bool {
            rig.screen.view.subviews.contains { ($0 as? UILabel)?.accessibilityIdentifier == "terminal.hostGridNote" && Screen.isShown($0, in: rig.window) }
        }

        // The Mac still has the old claim, then takes the new one: no note either time.
        rig.session.emit(.hostGrid(columns: first.columns, rows: first.rows))
        rig.session.write("\u{1B}[1;1Hold")
        try await TerminalPredictionInputTests.waitUntil(2) { (rig.screen.surface.activeAreaText() ?? "").contains("old") }
        #expect(!noteShown(), "a note for the phone's own grid before its resize landed")
        rig.session.remoteColumns = second.columns
        rig.session.remoteRows = second.rows
        rig.session.emit(.hostGrid(columns: second.columns, rows: second.rows))
        rig.session.write("\u{1B}[1;1Hnew")
        try await TerminalPredictionInputTests.waitUntil(2) { (rig.screen.surface.activeAreaText() ?? "").contains("new") }
        #expect(!noteShown(), "a note for the phone's own new grid")

        // Another device owns a grid equal to the phone's old claim: its note shows.
        rig.session.remoteColumns = first.columns
        rig.session.remoteRows = first.rows
        rig.session.emit(.hostGrid(columns: first.columns, rows: first.rows))
        rig.session.emit(.hostGridOwner("Rig Mac"))
        rig.session.write("\u{1B}[1;1Hmac")
        let note = "\(first.columns)×\(first.rows) · set by Rig Mac"
        try await TerminalPredictionInputTests.waitUntil(5) { rig.screen.hostGridOwner == "Rig Mac" && noteShown() }
        #expect(noteShown(), "no \"\(note)\" note for another device's grid at the phone's old claim")
    }

    /// Fleet UI capture of #42422 after feat-cmux-next's R1-1 (2cc0f36b): a
    /// TUI on another device's 30×12 grid, keyboard up. Once the keyboard
    /// settled the TUI got the rows above the composer and the grid showed
    /// whole at the top with room below it, but no note. The note was placed
    /// from the TUI host's frame in the page's layout pass, before the host
    /// itself was laid out for its new height: the stale host (still the
    /// keyboard-down rows, its bottom on the raised composer) put the grid's
    /// bottom above the terminal area, so the note was hidden, and nothing
    /// placed it again.
    @Test func aTUIGridKeepsItsNoteOnceTheKeyboardSettles() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let rig = try await Self.makeScreen()
        defer { rig.close() }
        rig.session.emit(.hostGrid(columns: 30, rows: 12))
        rig.session.emit(.hostGridOwner("Rig Mac"))
        rig.session.isAlternateScreen = true
        rig.session.emit(.alternateScreen(true))
        rig.session.write("\u{1B}[?1049h\u{1B}[H\u{1B}[2J\u{1B}[6;8HMac grid 30x12")
        let note = "30×12 · set by Rig Mac"
        try await TerminalPredictionInputTests.waitUntil(5) { rig.screen.model.isTUI && rig.visibleLabel(note) != nil }
        try #require(rig.visibleLabel(note) != nil, "no note with the keyboard down")
        let rowsDown = rig.screen.hostLayout.visibleRows

        // The soft keyboard shows and settles (UIKit's notifications, in this
        // app's screen coordinates): the TUI gets the rows above the composer.
        let screen = rig.window.screen.bounds
        let shown = CGRect(x: screen.minX, y: screen.maxY - 336, width: screen.width, height: 336)
        let hidden = CGRect(x: screen.minX, y: screen.maxY, width: screen.width, height: 336)
        let center = NotificationCenter.default
        func post(_ name: Notification.Name, _ frame: CGRect) {
            center.post(name: name, object: nil, userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame,
                                                            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0])
        }
        defer {
            post(UIResponder.keyboardWillChangeFrameNotification, hidden)
            post(UIResponder.keyboardWillHideNotification, hidden)
        }
        post(UIResponder.keyboardWillChangeFrameNotification, shown)
        post(UIResponder.keyboardWillShowNotification, shown)
        post(UIResponder.keyboardDidChangeFrameNotification, shown)
        post(UIResponder.keyboardDidShowNotification, shown)
        try await TerminalPredictionInputTests.waitUntil(2) { rig.screen.hostLayout.visibleRows < rowsDown }
        let rowsUp = rig.screen.hostLayout.visibleRows
        try #require(rowsUp < rowsDown, "the TUI kept its \(rowsDown) keyboard-down rows (the keyboard never settled)")
        try #require(rowsUp > 13, "only \(rowsUp) rows above the composer: no room for the note")

        try await TerminalPredictionInputTests.waitUntil(2) { rig.visibleLabel(note) != nil }
        let view = rig.screen.view!
        let cell = rig.screen.surface.cellSize.height
        let gridTop = rig.screen.surface.convert(CGPoint.zero, to: view).y
        let label = try #require(rig.visibleLabel(note),
                                 "no visible note with the keyboard up (\(rowsUp) rows, the grid's 12 rows from \(gridTop) to \(gridTop + 12 * cell))")
        // Below the grid's 12 rows, above the keyboard.
        #expect(label.frame.minY >= gridTop + 12 * cell - 0.5, "the note overlaps the grid (\(label.frame), rows end at \(gridTop + 12 * cell))")
        #expect(label.frame.minY <= gridTop + 12 * cell + 8.5, "the note is not under the grid (\(label.frame), rows end at \(gridTop + 12 * cell))")
        #expect(label.frame.maxY <= view.convert(shown, from: nil).minY, "the note is under the keyboard (\(label.frame))")
    }
}
#endif
