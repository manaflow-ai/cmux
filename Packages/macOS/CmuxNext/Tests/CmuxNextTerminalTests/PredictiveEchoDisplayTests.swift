import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// The echo predictions' display and overlay hooks: what shows in a key's turn, what
/// an echo, an input method, secure input or a write that is not a key does to it, and that the
/// setting's off makes no engine at all.
@MainActor
@Suite struct PredictiveEchoDisplayTests {
    /// A grid, a frame counter and what was drawn, in place of the surface view.
    final class Host: PredictiveEchoHost {
        var columns = 10
        var rows: [[UInt8]] = Array(repeating: Array(repeating: PredictiveEcho.blank, count: 10), count: 3)
        var cursor = (row: 0, column: 0)
        var isAlternateScreen = false
        var isSecureInput = false
        var isComposing = false
        var isTranslucent = false
        var predictionGeometry: PredictiveEchoGeometry? = PredictiveEchoGeometry(viewSize: CGSize(width: 480, height: 240),
                                                                                 cellSize: CGSize(width: 8, height: 16))
        private var frame = NSObject()
        private(set) var reads = 0
        private(set) var frameRequests = 0
        private(set) var shown: (cells: [PredictiveEcho.Cell], cursor: PredictiveEcho.Position?) = ([], nil)

        var presentedFrameID: ObjectIdentifier? { ObjectIdentifier(frame) }

        /// Ghostty drew a new frame.
        func present() { frame = NSObject() }

        /// The host's echo of printable text at the cursor, then a new frame.
        func echo(_ text: String) {
            for byte in text.utf8 {
                rows[cursor.row][cursor.column] = byte
                cursor.column += 1
            }
            present()
        }

        func readPredictionGrid(row: Int?, leftmost: Int?, readsBefore: Bool) -> PredictionRow? {
            reads += 1
            let row = row ?? cursor.row
            let start = min(cursor.column, leftmost ?? cursor.column)
            // Ghostty's plain text: the blank cells at the end of the row are left out.
            var text = Array(rows[row][start...])
            while text.last == PredictiveEcho.blank { text.removeLast() }
            let before = readsBefore && start > 0 ? [rows[row][start - 1]] : nil
            return PredictionRow(cursorRow: cursor.row, cursorColumn: cursor.column, columns: columns,
                                 isAlternateScreen: isAlternateScreen, row: row, start: start, text: text, beforeText: before)
        }

        func predictionsNeedFrames() { frameRequests += 1 }

        func showPredictions(_ cells: [PredictiveEcho.Cell], cursor: PredictiveEcho.Position?) {
            shown = (cells, cursor)
        }
    }

    let start = ContinuousClock.now

    func makeDisplay(_ host: Host, mode: TerminalPredictiveEcho.Mode = .always, remote: Bool = false) -> PredictiveEchoDisplay {
        let start = start
        return PredictiveEchoDisplay(config: TerminalPredictiveEcho(mode: mode, isRemoteSession: remote), host: host,
                                     now: { start })
    }

    /// "a" typed and echoed: the epoch is confirmed and the cursor is at column 1.
    func confirmed(_ host: Host, _ display: PredictiveEchoDisplay) {
        display.keySent(Array("a".utf8))
        #expect(host.shown.cells.isEmpty, "the first keystroke of an epoch showed before its echo")
        host.echo("a")
        #expect(display.frame() == false)
        #expect(display.engine.epoch.isConfirmed)
    }

    @Test func aKeyOfAConfirmedEpochShowsInItsOwnTurnAndItsEchoClearsIt() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        display.keySent(Array("b".utf8))
        #expect(host.shown.cells == [PredictiveEcho.Cell(row: 0, column: 1, glyph: UInt8(ascii: "b"))])
        #expect(host.shown.cursor == PredictiveEcho.Position(row: 0, column: 2))
        #expect(host.frameRequests >= 1, "a waiting prediction asked for no frames")

        host.echo("b")
        #expect(display.frame() == false)
        #expect(host.shown.cells.isEmpty)
        #expect(host.shown.cursor == nil)
    }

    @Test func aBackspaceCoversTheCellAndGhosttysCursor() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        display.keySent([PredictiveEcho.delete])
        // The deleted "a" shows as a blank, and the cell Ghostty's cursor is in (column 1) is covered.
        #expect(Set(host.shown.cells.map(\.column)) == [0, 1])
        #expect(host.shown.cells.allSatisfy { $0.glyph == PredictiveEcho.blank })
        #expect(host.shown.cursor == PredictiveEcho.Position(row: 0, column: 0))
    }

    @Test func noFrameWithoutANewGhosttyFrameOrADeadlineReadsTheGrid() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        display.keySent(Array("b".utf8))
        let reads = host.reads
        #expect(display.frame() == true)
        #expect(display.frame() == true)
        #expect(host.reads == reads, "a frame read the grid though Ghostty drew nothing")
        host.present()
        #expect(display.frame() == true)
        #expect(host.reads == reads + 1)
    }

    @Test func anInputMethodsMarkedTextPredictsNothing() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        host.isComposing = true
        display.keySent(Array("b".utf8))
        #expect(display.engine.pending.isEmpty)
        #expect(host.shown.cells.isEmpty)
    }

    @Test func markedTextHidesPredictionsAlreadyShown() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        display.keySent(Array("b".utf8))
        #expect(!host.shown.cells.isEmpty)
        host.isComposing = true
        #expect(display.frame() == false)
        #expect(host.shown.cells.isEmpty)
        #expect(display.engine.pending.isEmpty)
    }

    @Test func secureInputPredictsNothing() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        host.isSecureInput = true
        display.keySent(Array("b".utf8))
        #expect(display.engine.pending.isEmpty)
        #expect(host.shown.cells.isEmpty)
    }

    @Test func aTranslucentBackgroundPredictsNothingAndHidesWhatShows() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        display.keySent(Array("b".utf8))
        #expect(!host.shown.cells.isEmpty)
        // The person lowers the window's opacity while the echo is on its way.
        host.isTranslucent = true
        #expect(display.frame() == false)
        #expect(host.shown.cells.isEmpty)
        #expect(host.shown.cursor == nil)
        display.keySent(Array("c".utf8))
        #expect(display.engine.pending.isEmpty)
        #expect(host.shown.cells.isEmpty, "a prediction drew a solid cell on a translucent terminal")
    }

    @Test func aTallerViewWhilePredictionsShowClearsThemWithoutANewGhosttyFrame() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        display.keySent(Array("b".utf8))
        #expect(!host.shown.cells.isEmpty)
        // The split grows: rows count from the view's top, so the overlay's old frame is off its row.
        host.predictionGeometry?.viewSize.height += 64
        #expect(display.frame() == false)
        #expect(host.shown.cells.isEmpty)
        #expect(host.shown.cursor == nil)
        #expect(display.engine.pending.isEmpty)
    }

    @Test func aFontSizeChangeWhilePredictionsShowClearsThemOnTheNextKey() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        display.keySent(Array("b".utf8))
        #expect(!host.shown.cells.isEmpty)
        // Cmd-= writes nothing to the terminal; the cells grow under the predictions.
        host.predictionGeometry?.cellSize = CGSize(width: 9, height: 18)
        display.keySent(Array("c".utf8))
        #expect(host.shown.cells.isEmpty)
        #expect(host.shown.cursor == nil)
        #expect(display.engine.pending.isEmpty)
    }

    @Test func theSameGeometryKeepsThePredictions() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        display.keySent(Array("b".utf8))
        display.keySent(Array("c".utf8))
        #expect(host.shown.cells.map(\.glyph) == [UInt8(ascii: "b"), UInt8(ascii: "c")])
        #expect(display.frame() == true)
        #expect(display.engine.pending.count == 2)
    }

    @Test func theOverlayDrawsOpaqueCellsOnlyOnAnOpaqueBackground() throws {
        func theme(opacity: Double) -> GhosttyThemeColors {
            GhosttyThemeColors(background: .init(r: 10, g: 20, b: 30), foreground: .init(r: 200, g: 210, b: 220), palette: [],
                               selectionBackground: nil, selectionForeground: nil, cursor: nil,
                               backgroundOpacity: opacity, backgroundBlur: 0)
        }
        #expect(PredictiveEchoOverlay.colors(of: theme(opacity: 0.8), backgroundOverride: nil) == nil)
        #expect(PredictiveEchoOverlay.colors(of: theme(opacity: 0.8), backgroundOverride: .black) == nil)
        let opaque = try #require(PredictiveEchoOverlay.colors(of: theme(opacity: 1), backgroundOverride: nil))
        #expect(opaque.background.alphaComponent == 1)
        #expect(opaque.background == NSColor(srgbRed: 10.0 / 255, green: 20.0 / 255, blue: 30.0 / 255, alpha: 1))
        #expect(opaque.cursor == opaque.foreground, "no cursor-color draws the cursor in the foreground")
        let overridden = try #require(PredictiveEchoOverlay.colors(of: theme(opacity: 1), backgroundOverride: .black))
        #expect(overridden.background == .black)
    }

    @Test func aWriteThatIsNotAKeyDropsThePredictionsAndTheConfirmation() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        display.keySent(Array("b".utf8))
        #expect(!host.shown.cells.isEmpty)
        let reads = host.reads
        display.otherInput()
        #expect(host.reads == reads, "the write callback read the grid (Ghostty may hold its lock there)")
        #expect(host.shown.cells.isEmpty)
        #expect(!display.engine.epoch.isConfirmed)
        display.keySent(Array("c".utf8))
        #expect(host.shown.cells.isEmpty, "a key after a paste showed before an echo confirmed it")
    }

    @Test func aKeyThatWroteNothingLeavesThePredictions() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        display.keySent(Array("B".utf8))
        let reads = host.reads
        display.keySent([])  // Shift going up, or a binding Ghostty ran
        #expect(host.reads == reads)
        #expect(display.engine.pending.map(\.glyph) == [UInt8(ascii: "B")])
        #expect(display.engine.epoch.isConfirmed)
    }

    @Test func aControlByteStopsPredictingUntilTheEchoConfirmsAgain() {
        let host = Host()
        let display = makeDisplay(host)
        confirmed(host, display)
        display.keySent([0x0D])  // Return
        display.keySent(Array("x".utf8))
        #expect(!display.engine.epoch.isConfirmed)
        #expect(host.shown.cells.isEmpty, "a key after Return showed before an echo confirmed it")
    }

    @Test func remoteModeShowsForARemoteSessionOnly() {
        let local = Host()
        let localDisplay = makeDisplay(local, mode: .remote, remote: false)
        confirmed(local, localDisplay)
        localDisplay.keySent(Array("b".utf8))
        #expect(local.shown.cells.isEmpty, "a fast local echo showed predictions in remote mode")

        let remote = Host()
        let remoteDisplay = makeDisplay(remote, mode: .remote, remote: true)
        confirmed(remote, remoteDisplay)
        remoteDisplay.keySent(Array("b".utf8))
        #expect(!remote.shown.cells.isEmpty)
    }

    @Test func theSettingsValuesNameTheModes() {
        #expect(TerminalPredictiveEcho.Mode(setting: "remote") == .remote)
        #expect(TerminalPredictiveEcho.Mode(setting: "always") == .always)
        #expect(TerminalPredictiveEcho.Mode(setting: "off") == nil)
        #expect(TerminalPredictiveEcho.Mode(setting: "") == nil)
    }

    // MARK: The grid read

    @Test func ghosttysRowTextBecomesCells() {
        let row = PredictionRow(cursorRow: 0, cursorColumn: 2, columns: 6, isAlternateScreen: false, row: 0, start: 2,
                                text: Array("a b".utf8), beforeText: Array("x".utf8))
        #expect((0..<7).map { row.glyph(row: 0, column: $0) }
                    == [nil, UInt8(ascii: "x"), UInt8(ascii: "a"), 0x20, UInt8(ascii: "b"), 0x20, nil])
        #expect(row.glyph(row: 1, column: 2) == nil)
    }

    @Test func aWideOrCombiningGlyphMakesItsCellsAndTheRestUnknown() {
        let cells = PredictionRow.cells(of: Array("ab\u{65E5}c".utf8), count: 6)
        #expect(cells == [UInt8(ascii: "a"), nil, nil, nil, nil, nil])
    }

    @Test func aCellLeftOfTheReadIsKnownOnlyAsOnePrintableByte() {
        func before(_ text: [UInt8]?) -> UInt8? {
            PredictionRow(cursorRow: 0, cursorColumn: 1, columns: 4, isAlternateScreen: false, row: 0, start: 1,
                          text: [], beforeText: text).glyph(row: 0, column: 0)
        }
        #expect(before(Array("q".utf8)) == UInt8(ascii: "q"))
        // An empty cell and a wide glyph's second half both read as no text.
        #expect(before([]) == nil)
        #expect(before(Array("\u{65E5}".utf8)) == nil)
        #expect(before(nil) == nil)
    }

    @Test func aFailedReadIsAllUnknown() {
        let row = PredictionRow(cursorRow: 0, cursorColumn: 0, columns: 3, isAlternateScreen: false, row: 0, start: 0,
                                text: nil, beforeText: nil)
        #expect((0..<3).allSatisfy { row.glyph(row: 0, column: $0) == nil })
    }

    // MARK: A live surface

    final class Delegate: TerminalSessionDelegate {
        var mode: TerminalPredictiveEcho.Mode?
        init(_ mode: TerminalPredictiveEcho.Mode?) { self.mode = mode }
        func terminalSessionPredictiveEcho(_ session: TerminalSession) -> TerminalPredictiveEcho.Mode? { mode }
    }

    /// A live surface in a window, its keys through its own keyDown.
    final class Rig {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let delegate: Delegate

        init(_ mode: TerminalPredictiveEcho.Mode?) {
            _ = NSApplication.shared
            session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            delegate = Delegate(mode)
            session.delegate = delegate
            window.isReleasedWhenClosed = false
            window.contentView = session.view
        }

        var slot: PredictiveEchoSlot { session.surfaceView.bridge.takeUnretainedValue().input.predictions }

        func type(_ text: String, keyCode: UInt16) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                      windowNumber: window.windowNumber, context: nil, characters: text,
                                                      charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode))
            session.surfaceView.keyDown(with: event)
        }

        func close() {
            io.finish()
            session.close()
            window.close()
        }
    }

    @Test func offMakesNoEngine() throws {
        let rig = Rig(nil)
        defer { rig.close() }
        try #require(rig.session.surfaceView.surface != nil, "libghostty created no surface")
        try rig.type("a", keyCode: 0)
        try rig.type("s", keyCode: 1)
        #expect(rig.slot.display == nil)

        rig.delegate.mode = .always
        try rig.type("d", keyCode: 2)
        #expect(rig.slot.display != nil)
        rig.delegate.mode = nil
        try rig.type("f", keyCode: 3)
        #expect(rig.slot.display == nil, "turning the setting off kept the engine")
    }

    @Test func aKeysOwnWriteReachesTheEngineInItsTurn() throws {
        let rig = Rig(.always)
        defer { rig.close() }
        try #require(rig.session.surfaceView.surface != nil, "libghostty created no surface")
        try rig.type("a", keyCode: 0)  // makes the display; this key is not predicted
        try rig.type("s", keyCode: 1)
        let display = try #require(rig.slot.display)
        #expect(display.engine.pending.map(\.glyph) == [UInt8(ascii: "s")])
    }

    @Test func markedTextOnTheSurfacePredictsNothing() throws {
        let rig = Rig(.always)
        defer { rig.close() }
        try #require(rig.session.surfaceView.surface != nil, "libghostty created no surface")
        try rig.type("a", keyCode: 0)
        try rig.type("s", keyCode: 1)
        let display = try #require(rig.slot.display)
        #expect(display.engine.pending.count == 1)
        // An input method starts composing: its preedit takes the cursor's cells.
        rig.session.surfaceView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                                              replacementRange: NSRange(location: NSNotFound, length: 0))
        rig.session.surfaceView.noteKeyTaken()
        #expect(display.engine.pending.isEmpty)
    }
}
