@testable import CmuxNextTerminal
import Testing

/// The mosh-rules echo predictor: what it predicts, when it shows, and that every rollback leaves
/// nothing drawn.
struct PredictiveEchoTests {
    nonisolated struct Screen: PredictionScreen {
        var cursorRow = 0
        var cursorColumn = 0
        var columns: Int
        var isAlternateScreen = false
        var rows: [[UInt8]]

        init(columns: Int = 10, rows: Int = 3) {
            self.columns = columns
            self.rows = Array(repeating: Array(repeating: PredictiveEcho.blank, count: columns), count: rows)
        }

        func glyph(row: Int, column: Int) -> UInt8? {
            guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
            return rows[row][column]
        }

        /// The host echoing printable text at the cursor.
        mutating func echo(_ text: String) {
            for byte in text.utf8 {
                rows[cursorRow][cursorColumn] = byte
                cursorColumn += 1
            }
        }

        /// The host's echo of a backspace: "\b \b".
        mutating func echoBackspace() {
            cursorColumn -= 1
            rows[cursorRow][cursorColumn] = PredictiveEcho.blank
        }
    }

    let start = ContinuousClock.now

    func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(milliseconds))
    }

    func cells(_ engine: PredictiveEcho) -> [PredictiveEcho.Cell] {
        var cells: [PredictiveEcho.Cell] = []
        engine.forEachVisibleCell { cells.append($0) }
        return cells
    }

    func expectRolledBack(_ engine: PredictiveEcho, from epoch: PredictionEpoch) {
        #expect(engine.pending.isEmpty)
        #expect(!engine.isShowing)
        #expect(cells(engine).isEmpty)
        #expect(engine.predictedCursor == nil)
        #expect(engine.epoch.id == epoch.id + 1)
        #expect(!engine.epoch.isConfirmed)
    }

    /// A confirmed .always engine with the cursor at column 1 after "a" echoed.
    func confirmedEngine(_ screen: inout Screen) -> PredictiveEcho {
        var engine = PredictiveEcho(mode: .always)
        engine.typed(Array("a".utf8), on: screen, at: at(0))
        screen.echo("a")
        engine.hostOutput(on: screen, at: at(5))
        return engine
    }

    @Test func theFirstKeystrokeOfAnEpochStaysHiddenUntilItsEchoConfirmsIt() {
        var screen = Screen()
        var engine = PredictiveEcho(mode: .always)
        engine.typed(Array("a".utf8), on: screen, at: at(0))
        #expect(engine.pending.count == 1)
        #expect(!engine.isShowing)
        #expect(cells(engine).isEmpty)

        screen.echo("a")
        engine.hostOutput(on: screen, at: at(5))
        #expect(engine.epoch.isConfirmed)
        #expect(engine.pending.isEmpty)

        engine.typed(Array("bc".utf8), on: screen, at: at(10))
        #expect(engine.isShowing)
        #expect(cells(engine) == [PredictiveEcho.Cell(row: 0, column: 1, glyph: UInt8(ascii: "b")),
                                  PredictiveEcho.Cell(row: 0, column: 2, glyph: UInt8(ascii: "c"))])
        #expect(engine.predictedCursor == PredictiveEcho.Position(row: 0, column: 3))
    }

    @Test func anEchoOfPartOfThePredictionsSettlesOnlyThatPart() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed(Array("bc".utf8), on: screen, at: at(10))
        screen.echo("b")
        engine.hostOutput(on: screen, at: at(15))
        #expect(engine.pending.map(\.glyph) == [UInt8(ascii: "c")])
        #expect(engine.isShowing)
        screen.echo("c")
        engine.hostOutput(on: screen, at: at(20))
        #expect(engine.pending.isEmpty)
        #expect(!engine.isShowing)
    }

    @Test func outputBeforeTheEchoThatLeavesTheCursorKeepsThePredictions() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed(Array("b".utf8), on: screen, at: at(10))
        screen.rows[2][0] = UInt8(ascii: "x")
        engine.hostOutput(on: screen, at: at(15))
        #expect(engine.pending.count == 1)
        #expect(engine.isShowing)
    }

    @Test func aWrongEchoRollsEverythingBack() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed(Array("bc".utf8), on: screen, at: at(10))
        let epoch = engine.epoch
        screen.echo("B")
        engine.hostOutput(on: screen, at: at(15))
        expectRolledBack(engine, from: epoch)

        // The next keystroke belongs to the new epoch and stays hidden until its own echo.
        engine.typed(Array("d".utf8), on: screen, at: at(20))
        #expect(engine.pending.count == 1)
        #expect(!engine.isShowing)
    }

    /// mosh `become_tentative`: "ls" then Enter inside one RTT must not blank "ls" until its echo.
    @Test func escapeReturnAndControlBytesKeepShownPredictionsUntilTheirEcho() {
        for byte: UInt8 in [0x1B, 0x0D, 0x03, 0x09, 0xC3] {
            var screen = Screen()
            var engine = confirmedEngine(&screen)
            engine.typed(Array("b".utf8), on: screen, at: at(10))
            let epoch = engine.epoch
            engine.typed([byte], on: screen, at: at(11))
            #expect(cells(engine) == [PredictiveEcho.Cell(row: 0, column: 1, glyph: UInt8(ascii: "b"))])
            // The refused byte may move the cursor, so the real one shows.
            #expect(engine.predictedCursor == nil)
            #expect(engine.epoch.id == epoch.id + 1)
            #expect(!engine.epoch.isConfirmed)

            // Nothing more is predicted until "b" settles.
            engine.typed(Array("c".utf8), on: screen, at: at(12))
            #expect(engine.pending.map(\.glyph) == [UInt8(ascii: "b")])

            screen.echo("b")
            engine.hostOutput(on: screen, at: at(15))
            #expect(engine.pending.isEmpty)
            #expect(engine.epoch.hasConfirmed(epoch.id))

            // The new epoch's first keystroke stays hidden until its own echo.
            engine.typed(Array("d".utf8), on: screen, at: at(20))
            #expect(engine.pending.count == 1)
            #expect(!engine.isShowing)
        }
    }

    @Test func anEchoThatLeavesTheRowAfterReturnRetiresThePredictions() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed(Array("ls".utf8), on: screen, at: at(10))
        engine.typed([0x0D], on: screen, at: at(11))
        let epoch = engine.epoch
        #expect(cells(engine).count == 2)

        // "ls", CR LF and the command's first line arrive in one read.
        screen.echo("ls")
        screen.cursorRow = 1
        screen.cursorColumn = 0
        engine.hostOutput(on: screen, at: at(15))
        #expect(engine.pending.isEmpty)
        #expect(cells(engine).isEmpty)
        #expect(engine.epoch == epoch)
    }

    @Test func aRefusedByteInTheMiddleOfAChunkEndsTheChunk() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        let epoch = engine.epoch
        engine.typed([UInt8(ascii: "b"), 0x1B, UInt8(ascii: "c")], on: screen, at: at(10))
        #expect(engine.pending.map(\.glyph) == [UInt8(ascii: "b")])
        #expect(engine.isShowing)
        #expect(engine.epoch.id == epoch.id + 1)
    }

    @Test func aCursorMoveOnTheRowWaitsForTheEchoAndARowChangeRollsBack() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed(Array("b".utf8), on: screen, at: at(10))
        let epoch = engine.epoch
        screen.cursorColumn = 7
        engine.hostOutput(on: screen, at: at(15))
        #expect(engine.pending.count == 1)
        #expect(engine.epoch == epoch)
        // The echo never comes: the expiry rolls back.
        engine.expire(on: screen, at: at(10).advanced(by: engine.expiry))
        expectRolledBack(engine, from: epoch)

        var other = Screen()
        var moved = confirmedEngine(&other)
        moved.typed(Array("b".utf8), on: other, at: at(10))
        let movedEpoch = moved.epoch
        other.cursorRow = 1
        other.cursorColumn = 0
        moved.hostOutput(on: other, at: at(15))
        expectRolledBack(moved, from: movedEpoch)
    }

    /// A shell redraw split across reads (zsh-syntax-highlighting, fish: CR, then the line again)
    /// is not a mismatch; mosh keeps such a prediction pending until the host acknowledged it.
    @Test func aRedrawSplitAcrossReadsKeepsThePredictionsAndSettlesWithCredit() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed(Array("bc".utf8), on: screen, at: at(10))
        let epoch = engine.epoch

        screen.cursorColumn = 0
        engine.hostOutput(on: screen, at: at(15))
        #expect(engine.pending.count == 2)
        #expect(engine.isShowing)
        #expect(engine.epoch == epoch)

        screen.echo("abc")
        engine.hostOutput(on: screen, at: at(20))
        #expect(engine.pending.isEmpty)
        #expect(engine.epoch.isConfirmed)
        #expect(engine.smoothedRTT != .milliseconds(5))
    }

    /// zsh-autosuggestions: the echo of "b" also draws gray text right of the cursor, over the
    /// still-pending "c". An insert and an overwrite now look the same, so nothing is predicted.
    @Test func textDrawnRightOfPendingPredictionsRollsBack() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed(Array("bc".utf8), on: screen, at: at(10))
        let epoch = engine.epoch
        screen.echo("b")
        for (offset, byte) in "rep".utf8.enumerated() { screen.rows[0][2 + offset] = byte }
        engine.hostOutput(on: screen, at: at(15))
        expectRolledBack(engine, from: epoch)

        // The next keystroke sees the text too and is not predicted.
        engine.typed(Array("d".utf8), on: screen, at: at(20))
        #expect(engine.pending.isEmpty)

        // The keystroke check holds on its own, before the overlay passes the echo on.
        var unparsed = Screen()
        var typing = confirmedEngine(&unparsed)
        typing.typed(Array("bc".utf8), on: unparsed, at: at(10))
        let typingEpoch = typing.epoch
        unparsed.echo("b")
        for (offset, byte) in "rep".utf8.enumerated() { unparsed.rows[0][2 + offset] = byte }
        typing.typed(Array("d".utf8), on: unparsed, at: at(16))
        expectRolledBack(typing, from: typingEpoch)
    }

    @Test func theAlternateScreenIsNeverPredictedAndSwitchingToItRollsBack() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed(Array("b".utf8), on: screen, at: at(10))
        let epoch = engine.epoch
        screen.isAlternateScreen = true
        engine.hostOutput(on: screen, at: at(15))
        expectRolledBack(engine, from: epoch)

        engine.typed(Array("x".utf8), on: screen, at: at(20))
        #expect(engine.pending.isEmpty)
        #expect(cells(engine).isEmpty)
    }

    @Test func secureInputRollsBackAndBlocksPrediction() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed(Array("b".utf8), on: screen, at: at(10))
        let epoch = engine.epoch
        engine.update(.init(isRemoteSession: true, isSecureInput: true))
        expectRolledBack(engine, from: epoch)

        engine.typed(Array("secret".utf8), on: screen, at: at(20))
        #expect(engine.pending.isEmpty)
        #expect(!engine.isShowing)

        engine.update(.init(isRemoteSession: true, isSecureInput: false))
        engine.typed(Array("b".utf8), on: screen, at: at(30))
        #expect(engine.pending.count == 1)
        #expect(!engine.isShowing)
    }

    @Test func backspaceBlanksTheCellLeftOfTheCursorAndItsEchoConfirms() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed(Array("bc".utf8), on: screen, at: at(10))
        screen.echo("bc")
        engine.hostOutput(on: screen, at: at(15))

        engine.typed([PredictiveEcho.delete], on: screen, at: at(20))
        #expect(cells(engine) == [PredictiveEcho.Cell(row: 0, column: 2, glyph: PredictiveEcho.blank)])
        #expect(engine.predictedCursor == PredictiveEcho.Position(row: 0, column: 2))

        screen.echoBackspace()
        engine.hostOutput(on: screen, at: at(25))
        #expect(engine.pending.isEmpty)
        #expect(engine.epoch.isConfirmed)
    }

    @Test func aTypedCharacterThenBackspaceDrawsOnlyTheLatestGlyphPerCell() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed([UInt8(ascii: "b"), PredictiveEcho.delete, UInt8(ascii: "c")], on: screen, at: at(10))
        #expect(cells(engine) == [PredictiveEcho.Cell(row: 0, column: 1, glyph: UInt8(ascii: "c"))])
        #expect(engine.predictedCursor == PredictiveEcho.Position(row: 0, column: 2))

        // The host echoes "b", "\b \b" and "c" in one chunk: all three settle.
        screen.echo("b")
        screen.echoBackspace()
        screen.echo("c")
        engine.hostOutput(on: screen, at: at(15))
        #expect(engine.pending.isEmpty)
    }

    @Test func backspaceAtTheLeftMarginRollsBack() {
        let screen = Screen()
        var engine = PredictiveEcho(mode: .always)
        let epoch = engine.epoch
        engine.typed([PredictiveEcho.delete], on: screen, at: at(0))
        expectRolledBack(engine, from: epoch)
    }

    @Test func theRightMarginIsNotPredicted() {
        var screen = Screen(columns: 4)
        var engine = confirmedEngine(&screen)
        engine.typed(Array("bc".utf8), on: screen, at: at(10))
        #expect(engine.pending.count == 2)
        let epoch = engine.epoch
        engine.typed(Array("d".utf8), on: screen, at: at(11))
        #expect(engine.pending.map(\.glyph) == [UInt8(ascii: "b"), UInt8(ascii: "c")])
        #expect(engine.epoch.id == epoch.id + 1)
    }

    @Test func textRightOfTheCursorIsNotPredicted() {
        var screen = Screen()
        screen.rows[0][5] = UInt8(ascii: "z")
        var engine = PredictiveEcho(mode: .always)
        let epoch = engine.epoch
        engine.typed(Array("a".utf8), on: screen, at: at(0))
        expectRolledBack(engine, from: epoch)
    }

    @Test func remoteModeShowsOnlyForARemoteSessionOrHighRTT() {
        // Local echo at 5 ms: confirmed, but below the 30 ms trigger.
        var screen = Screen()
        var engine = PredictiveEcho(mode: .remote)
        engine.typed(Array("a".utf8), on: screen, at: at(0))
        screen.echo("a")
        engine.hostOutput(on: screen, at: at(5))
        engine.typed(Array("b".utf8), on: screen, at: at(10))
        #expect(engine.epoch.isConfirmed)
        #expect(engine.smoothedRTT == .milliseconds(5))
        #expect(!engine.isShowing)

        // A remote session shows at any RTT.
        engine.update(.init(isRemoteSession: true))
        #expect(engine.isShowing)

        // A 100 ms echo shows without the remote flag.
        var slowScreen = Screen()
        var slow = PredictiveEcho(mode: .remote)
        slow.typed(Array("a".utf8), on: slowScreen, at: at(0))
        slowScreen.echo("a")
        slow.hostOutput(on: slowScreen, at: at(100))
        slow.typed(Array("b".utf8), on: slowScreen, at: at(110))
        #expect(slow.smoothedRTT == .milliseconds(100))
        #expect(slow.isRTTTriggered)
        #expect(slow.isShowing)
    }

    @Test func theRTTTriggerHasHysteresis() {
        var screen = Screen(columns: 80)
        var engine = PredictiveEcho(mode: .remote)
        engine.typed(Array("a".utf8), on: screen, at: at(0))
        screen.echo("a")
        engine.hostOutput(on: screen, at: at(40))
        #expect(engine.isRTTTriggered)

        // Fast echoes pull the smoothed RTT down; it stays on until below 20 ms.
        var now = 100
        var hidden = false
        for _ in 0..<40 {
            engine.typed(Array("b".utf8), on: screen, at: at(now))
            screen.echo("b")
            engine.hostOutput(on: screen, at: at(now + 1))
            let smoothed = engine.smoothedRTT ?? .zero
            if smoothed > PredictiveEcho.rttHideThreshold { #expect(engine.isRTTTriggered) }
            if !engine.isRTTTriggered {
                #expect(smoothed <= PredictiveEcho.rttHideThreshold)
                hidden = true
                break
            }
            now += 10
        }
        #expect(hidden)
    }

    /// mosh's glitch trigger: a stalled echo on a fast link shows predictions, and 10 quick echoes
    /// (at most one per 150 ms) hide them again.
    @Test func aStalledEchoShowsPredictionsUntilTenQuickEchoes() {
        var screen = Screen(columns: 80)
        var engine = PredictiveEcho(mode: .remote)
        engine.typed(Array("a".utf8), on: screen, at: at(0))
        screen.echo("a")
        engine.hostOutput(on: screen, at: at(5))
        engine.typed(Array("b".utf8), on: screen, at: at(10))
        #expect(!engine.isShowing)

        // The overlay's timer fires 250 ms after the keystroke, during the stall.
        #expect(engine.deadline == at(260))
        engine.expire(on: screen, at: at(260))
        #expect(engine.glitchRepairsLeft == PredictiveEcho.glitchRepairCount)
        #expect(engine.isShowing)
        #expect(engine.deadline == at(10).advanced(by: engine.expiry))

        screen.echo("b")
        engine.hostOutput(on: screen, at: at(310))
        #expect(engine.glitchRepairsLeft == PredictiveEcho.glitchRepairCount)

        var now = 400
        for _ in 0..<PredictiveEcho.glitchRepairCount {
            engine.typed(Array("c".utf8), on: screen, at: at(now))
            #expect(engine.isShowing)
            screen.echo("c")
            engine.hostOutput(on: screen, at: at(now + 5))
            now += 200
        }
        #expect(engine.glitchRepairsLeft == 0)
        #expect(!engine.isRTTTriggered)
        engine.typed(Array("d".utf8), on: screen, at: at(now))
        #expect(!engine.isShowing)
    }

    @Test func aStallSeenOnlyAtTheEchoStillTriggers() {
        var screen = Screen()
        var engine = PredictiveEcho(mode: .remote)
        engine.typed(Array("a".utf8), on: screen, at: at(0))
        screen.echo("a")
        engine.hostOutput(on: screen, at: at(5))
        engine.typed(Array("b".utf8), on: screen, at: at(10))
        screen.echo("b")
        engine.hostOutput(on: screen, at: at(400))
        #expect(engine.glitchRepairsLeft == PredictiveEcho.glitchRepairCount)
        engine.typed(Array("c".utf8), on: screen, at: at(410))
        #expect(engine.isShowing)
    }

    @Test func anEchoThatNeverComesExpiresAndRollsBack() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed(Array("p".utf8), on: screen, at: at(10))
        #expect(engine.deadline == at(10).advanced(by: PredictiveEcho.glitchThreshold))
        let epoch = engine.epoch
        engine.expire(on: screen, at: at(20))
        #expect(engine.pending.count == 1)
        engine.expire(on: screen, at: at(10).advanced(by: PredictiveEcho.glitchThreshold))
        #expect(engine.pending.count == 1)
        #expect(engine.deadline == at(10).advanced(by: engine.expiry))
        engine.expire(on: screen, at: at(10).advanced(by: engine.expiry))
        expectRolledBack(engine, from: epoch)
        #expect(engine.deadline == nil)
    }

    @Test func predictionsTheGridAlreadyShowsExpireQuietly() {
        var screen = Screen()
        var engine = confirmedEngine(&screen)
        engine.typed([UInt8(ascii: "b"), PredictiveEcho.delete], on: screen, at: at(10))
        let epoch = engine.epoch
        // "b" then "\b \b" echoed in one chunk leave the grid as it was: no credit, keep waiting.
        engine.hostOutput(on: screen, at: at(15))
        #expect(engine.pending.count == 2)
        engine.expire(on: screen, at: at(10).advanced(by: engine.expiry))
        #expect(engine.pending.isEmpty)
        #expect(engine.epoch == epoch)
    }

    @Test func aPasteBeyondThePendingLimitStopsPredicting() {
        var screen = Screen(columns: 200)
        var engine = confirmedEngine(&screen)
        let epoch = engine.epoch
        engine.typed(Array(repeating: UInt8(ascii: "x"), count: PredictiveEcho.maxPending + 1),
                     on: screen, at: at(10))
        #expect(engine.pending.count == PredictiveEcho.maxPending)
        #expect(engine.epoch.id == epoch.id + 1)
        #expect(engine.predictedCursor == nil)
    }
}
