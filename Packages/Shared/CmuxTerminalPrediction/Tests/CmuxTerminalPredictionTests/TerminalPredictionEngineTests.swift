import Testing
@testable import CmuxTerminalPrediction

/// Drives the engine the way the host does: keystrokes in, PTY bytes back.
private struct Session {
    var engine = TerminalPredictionEngine(isEnabled: true, isRemoteSurface: true)
    var clock: Duration = .zero

    mutating func advance(_ step: Duration) { clock += step }

    mutating func type(_ text: String, after step: Duration = .milliseconds(10)) {
        advance(step)
        engine.typed(text, at: clock)
    }

    mutating func remote(_ text: String, after step: Duration = .milliseconds(70)) {
        advance(step)
        engine.observedOutput(Array(text.utf8), at: clock)
    }

    /// The characters drawn, without the blanks over deleted cells.
    var drawn: String {
        String(engine.glyphs.filter { $0.standing != .erased }.map(\.character))
    }

    /// Offsets of the cells drawn blank because the user deleted them.
    var blanks: [Int] {
        engine.glyphs.filter { $0.standing == .erased }.map(\.offset)
    }

    var liveOffsets: [Int] {
        engine.glyphs.filter { $0.standing != .erased }.map(\.offset)
    }
}

/// Reaches the state where the engine is willing to draw: two echoed
/// characters over a link slow enough to be worth predicting.
private func armedSession() -> Session {
    var session = Session()
    session.type("l")
    session.remote("l")
    session.type("s")
    session.remote("s")
    session.engine.presentedFrame(at: session.clock)
    return session
}

struct TerminalPredictionEngineTests {
    @Test func drawsNothingBeforeTheRemoteHasEchoedAnything() {
        var session = Session()
        session.type("l")

        #expect(session.drawn == "")
        #expect(session.engine.status(at: session.clock) == .listening)
    }

    @Test func aPasswordPromptNeverDisplaysATypedCharacter() {
        // Established echo run at the shell, then sudo prints its prompt and
        // stops echoing. Every keystroke after that must stay invisible.
        var session = armedSession()
        session.remote("\r\n[sudo] password for leo: ")

        for character in ["h", "u", "n", "t", "e", "r", "2"] {
            session.type(character)
            #expect(session.drawn == "")
        }
        #expect(session.engine.status(at: session.clock) == .listening)
    }

    @Test func anUnterminatedStringSequenceDoesNotHideAPasswordPrompt() {
        // An interrupted image transfer leaves an APC open. Ghostty closes it
        // at the next ESC and prints the prompt; the engine must see the
        // prompt too, or it keeps the echo run alive and draws the password.
        var session = armedSession()
        session.remote("\u{1B}_Gi=1\u{1B}[2J\r\n[sudo] password for leo: ")

        for character in ["h", "u", "n", "t", "e", "r", "2"] {
            session.type(character)
            #expect(session.drawn == "")
        }
    }

    @Test func outputThatArrivedBeforeTheKeystrokeIsNotItsEcho() {
        // The IO thread stamps arrivals; the main actor drains them later. A
        // key typed in between must not claim output that was already in
        // flight, or a prompt could arm the echo run.
        //
        // The link is already measured slow, so claiming that output re-arms
        // a run that draws the next key. A fresh session would not show the
        // bug: its first latency sample would be negative, and a link that
        // measures fast draws nothing either way.
        var session = armedSession()
        session.remote("\r\n")
        #expect(session.engine.status(at: session.clock) == .listening)

        session.advance(.milliseconds(10))
        let arrival = session.clock
        session.type("$")
        session.engine.observedOutput(Array("$".utf8), at: arrival)

        session.type("s")
        #expect(session.drawn == "")
        #expect(session.engine.observedEchoLatency == .milliseconds(70))
    }

    @Test func anEraseThatArrivedBeforeTheBackspaceIsNotItsEcho() {
        // The erase counterpart of the case above: a cursor-left and clear
        // already in flight when Backspace was pressed must not complete
        // that Backspace's erase, or the glyph typed after it stays drawn
        // while the real erase is still to come.
        var session = armedSession()
        let typedA = session.clock + .milliseconds(10)
        session.type("a")
        session.type("\u{7F}")
        let typedBackspace = session.clock
        session.type("b")
        #expect(session.drawn == "b")

        session.engine.observedOutput(Array("a".utf8), at: typedA + .milliseconds(5))
        session.engine.observedOutput(
            Array("\u{8}\u{1B}[K".utf8),
            at: typedBackspace - .milliseconds(1)
        )
        #expect(session.drawn == "")
    }

    @Test func predictsOnceTheEchoRunIsEstablished() {
        var session = armedSession()

        session.type("s")
        #expect(session.drawn == "s")
        #expect(session.engine.glyphs.first?.standing == .speculative)

        session.type("-")
        session.type("a")
        #expect(session.drawn == "s-a")
        #expect(session.liveOffsets == [0, 1, 2])
    }

    @Test func aConsumedBindingDoesNotRaiseAnInputBarrier() {
        var session = armedSession()
        session.type("s")
        session.engine.typedNothing(at: session.clock + .milliseconds(1))
        session.type("-")

        #expect(session.drawn == "s-")
        #expect(session.engine.status(at: session.clock) == .predicting)
    }

    @Test func aConfirmedGlyphKeepsDrawingUntilAFrameIsPresented() {
        // The tee fires before the VT parser, so dropping the glyph at
        // confirmation blanks the cell until the paint catches up.
        var session = armedSession()
        session.type("s")
        session.remote("s")

        #expect(session.drawn == "s")
        #expect(session.engine.glyphs.first?.standing == .confirmed)

        session.advance(.milliseconds(5))
        session.engine.presentedFrame(at: session.clock)
        #expect(session.drawn == "")
    }

    @Test func offsetsShiftDownAsConfirmedGlyphsRetire() {
        var session = armedSession()
        session.type("a")
        session.type("b")
        #expect(session.liveOffsets == [0, 1])

        session.remote("a")
        session.advance(.milliseconds(5))
        session.engine.presentedFrame(at: session.clock)

        #expect(session.drawn == "b")
        #expect(session.liveOffsets == [0])
    }

    @Test func aConfirmedGlyphSitsLeftOfTheLiveCursor() {
        // The host anchors on ghostty's cursor, which the parser has already
        // advanced past the echo. The held glyph has to land on the cell the
        // echo went to, not one to the right of it.
        var session = armedSession()
        session.type("a")
        session.type("b")
        session.remote("a")

        #expect(session.drawn == "ab")
        #expect(session.liveOffsets == [-1, 0])
        #expect(session.engine.glyphs.map(\.standing) == [.confirmed, .speculative])

        session.remote("b", after: .milliseconds(1))
        #expect(session.liveOffsets == [-2, -1])
    }

    @Test func keystrokesTypedBeforeArmingStillOccupyTheirCells() {
        // "a" and "b" go out before any echo, so neither is drawn. The echo
        // of "a" arms the run; "c" is then drawn, and has to land after the
        // cell "b" is about to take rather than on top of it.
        var session = Session()
        session.type("x")
        session.remote("x")
        session.type("a")
        session.type("b", after: .milliseconds(5))
        session.remote("a")
        #expect(session.drawn == "")

        session.type("c", after: .milliseconds(5))
        #expect(session.drawn == "c")
        #expect(session.liveOffsets == [1])

        // "b" arrives: never drawn, so nothing is held, and "c" is now the
        // cell under the cursor. (The first echo, of "x", only starts the
        // streak that the echo of "a" completes.)
        session.remote("b", after: .milliseconds(1))
        #expect(session.liveOffsets == [0])
        #expect(session.engine.glyphs.map(\.standing) == [.speculative])
    }

    @Test func aContradictedPredictionIsWithdrawnWhole() {
        var session = armedSession()
        session.type("s")
        session.type("t")
        #expect(session.drawn == "st")

        // Autocorrect, a completion, anything that is not the echo.
        session.remote("x")
        #expect(session.drawn == "")
        #expect(session.engine.status(at: session.clock) == .listening)
    }

    @Test func remoteOutputWeDidNotTypeEndsTheRun() {
        var session = armedSession()
        session.type("s")

        // Command output arriving at the cursor moves the cell our offsets are
        // measured from.
        session.remote("total 48\r\n")
        #expect(session.drawn == "")
        #expect(session.engine.status(at: session.clock) == .listening)
    }

    @Test func editingKeysAndReturnStopPredictingRatherThanGuess() {
        // Backspace is not here: over an unconfirmed glyph it retracts, which
        // the backspace tests below cover.
        for input in ["\r", "\u{1B}[3~", "\u{1B}[D", "\u{3}"] {
            var session = armedSession()
            session.type("s")
            #expect(session.drawn == "s")

            // The glyph already sent echoes ahead of the key, so it stays
            // drawn until then instead of vanishing and coming back.
            session.type(input)
            #expect(session.drawn == "s")
            session.type("x")
            #expect(session.drawn == "s")

            // Confirmed, it retires with the frame that paints its echo.
            session.remote("s")
            session.engine.presentedFrame(at: session.clock)
            #expect(session.drawn == "")
            session.type("y")
            #expect(session.drawn == "")
        }
    }

    @Test func returnAnsweredByANewlineIsNotAMisprediction() {
        // Typing a command and Return faster than the round trip: the remote
        // answers with the echo, then CR LF. The newline is Return doing what
        // it does, so repeating this never suspends prediction.
        var session = armedSession()
        for _ in 0..<6 {
            session.type("s")
            session.type("\r")
            session.remote("s\r\n$ ")
            session.engine.presentedFrame(at: session.clock)
            #expect(session.drawn == "")
            session.advance(.milliseconds(600))
            session.type("l")
            session.remote("l")
        }
        #expect(session.engine.status(at: session.clock) != .suspended)
    }

    @Test func aLineEraseAfterReturnLeavesTheSubmittedLineDrawn() {
        // Ctrl-U acts on the new line; the submitted one keeps its glyph
        // until its echo arrives.
        var session = armedSession()
        session.type("s")
        session.type("\r")
        session.advance(.milliseconds(10))
        session.engine.typedLineErase(at: session.clock)
        #expect(session.drawn == "s")
        #expect(session.blanks == [])
    }

    @Test func nonASCIITextIsNeverPredicted() {
        // Width is not one cell for CJK, and combining marks do not advance the
        // cursor at all.
        for input in ["é", "世", "👍"] {
            var session = armedSession()
            session.type(input)
            #expect(session.drawn == "")
        }
    }

    @Test func theAlternateScreenWithholdsPrediction() {
        var session = armedSession()
        session.type("s")
        #expect(session.drawn == "s")

        session.remote("\u{1B}[?1049h")
        #expect(session.drawn == "")
        #expect(session.engine.status(at: session.clock) == .alternateScreen)

        session.type("j")
        #expect(session.drawn == "")

        session.remote("\u{1B}[?1049l")
        #expect(session.engine.status(at: session.clock) == .listening)
    }

    @Test func aSeededAlternateScreenWithholdsPredictionUntilItExits() {
        // Prediction started with vim already open: no mode switch is ever
        // seen, and vim echoes typed characters in insert mode, which would
        // otherwise arm a run.
        var session = Session()
        session.engine.seedAlternateScreen(true)
        #expect(session.engine.status(at: session.clock) == .alternateScreen)

        session.type("l")
        session.remote("l")
        session.type("s")
        #expect(session.drawn == "")

        session.remote("\u{1B}[?1049l")
        #expect(session.engine.status(at: session.clock) == .listening)
    }

    @Test func aModeSwitchSeenInOutputOutranksTheSeed() {
        // Output is teed ahead of the terminal's parser, so a read taken at
        // the first keystroke can predate vim's switch the engine already saw.
        var session = Session()
        session.remote("\u{1B}[?1049h")
        session.engine.seedAlternateScreen(false)
        #expect(session.engine.status(at: session.clock) == .alternateScreen)
    }

    @Test func aFastLinkIsLeftAlone() {
        var session = Session()
        session.type("l")
        session.remote("l", after: .milliseconds(2))
        session.type("s")
        session.remote("s", after: .milliseconds(2))

        #expect(session.engine.status(at: session.clock) == .linkIsFastEnough)
        session.type("s")
        #expect(session.drawn == "")
    }

    @Test func slowEchoMeasurementDrivesTheDecisionToPredict() {
        var session = Session()
        session.type("l")
        session.remote("l", after: .milliseconds(70))
        #expect(session.engine.observedEchoLatency == .milliseconds(70))
        // One echo is what a tty in cooked mode gives a key typed ahead of a
        // password prompt; the second shows the remote really echoes.
        #expect(session.engine.status(at: session.clock) == .listening)

        session.type("s")
        session.remote("s", after: .milliseconds(70))
        #expect(session.engine.status(at: session.clock) == .predicting)
    }

    @Test func repeatedVisibleWithdrawalsSuspendPrediction() {
        var session = armedSession()

        for _ in 0..<4 {
            session.type("s")
            #expect(session.drawn == "s")
            session.remote("x")
            // Re-arm for the next cycle, once the dropped keystroke's echo
            // could no longer be in flight.
            session.advance(.milliseconds(200))
            session.type("l")
            session.remote("l")
            session.type("l")
            session.remote("l")
        }

        #expect(session.engine.status(at: session.clock) == .suspended)
        session.type("s")
        #expect(session.drawn == "")

        session.advance(.seconds(31))
        session.type("l")
        session.remote("l")
        session.type("l")
        session.remote("l")
        #expect(session.engine.status(at: session.clock) == .predicting)
    }

    @Test func aGlyphTheRemoteNeverEchoesIsWithdrawn() {
        var session = armedSession()
        session.type("s")
        #expect(session.drawn == "s")

        session.advance(.milliseconds(1501))
        session.engine.tick(at: session.clock)
        #expect(session.drawn == "")
    }

    @Test func aHostThatStopsPresentingFramesDoesNotPinAGlyph() {
        var session = armedSession()
        session.type("s")
        session.remote("s")
        #expect(session.drawn == "s")

        session.advance(.milliseconds(121))
        session.engine.tick(at: session.clock)
        #expect(session.drawn == "")
    }

    @Test func aLongBurstStopsPredictingInsteadOfRunningAway() {
        var session = armedSession()
        for _ in 0..<40 {
            session.type("x", after: .milliseconds(1))
        }
        #expect(session.engine.glyphs.count == 40)

        session.type("x", after: .milliseconds(1))
        #expect(session.drawn == "")
    }

    @Test func aSurfaceNotKnownToBeRemoteNeverPredicts() {
        // A local shell under load can echo slower than the threshold. It
        // must still never see a predicted glyph, and a host that has not
        // classified the surface yet gets the local behavior.
        var engine = TerminalPredictionEngine(isEnabled: true)
        engine.typed("l", at: .milliseconds(10))
        engine.observedOutput(Array("l".utf8), at: .milliseconds(80))
        engine.typed("s", at: .milliseconds(90))

        #expect(engine.glyphs.isEmpty)
        #expect(engine.status(at: .milliseconds(90)) == .localSurface)
    }

    @Test func classifyingTheSurfaceRemoteLetsTheNextEchoArm() {
        var engine = TerminalPredictionEngine(isEnabled: true)
        engine.typed("l", at: .milliseconds(10))
        engine.isRemoteSurface = true
        engine.typed("s", at: .milliseconds(20))
        engine.typed("t", at: .milliseconds(25))
        engine.observedOutput(Array("st".utf8), at: .milliseconds(90))
        engine.typed("x", at: .milliseconds(100))

        #expect(engine.status(at: .milliseconds(100)) == .predicting)
        #expect(engine.glyphs.map(\.character).last == "x")
    }

    @Test func untrackedInputWithdrawsAndKeepsLaterKeystrokesUndrawn() {
        // A paste lands between keystrokes. Its echo comes back ahead of the
        // next key's, so drawing that key at the cursor would put it where the
        // pasted text is about to go.
        var session = armedSession()
        session.type("s")
        #expect(session.drawn == "s")

        session.advance(.milliseconds(5))
        _ = session.engine.sentUntrackedInput(at: session.clock)
        // "s" was sent before the paste, so its echo still lands first.
        #expect(session.drawn == "s")

        session.type("x")
        #expect(session.drawn == "s")
        session.remote("s")
        session.engine.presentedFrame(at: session.clock)
        #expect(session.drawn == "")
        session.remote("foo")
        session.remote("x")
        #expect(session.drawn == "")
    }

    @Test func theSettingGatesEverything() {
        var session = Session()
        session.engine.isEnabled = false
        session.type("l")
        session.remote("l")
        session.type("s")

        #expect(session.drawn == "")
        #expect(session.engine.status(at: session.clock) == .disabled)
    }

    @Test func syntaxHighlightingAroundTheEchoStillConfirms() {
        // zsh and fish wrap the echoed character in SGR. Treating colour as a
        // screen change would withdraw a correct prediction on every keystroke.
        var session = armedSession()
        session.type("s")
        session.remote("\u{1B}[0m\u{1B}[32ms\u{1B}[0m")

        #expect(session.drawn == "s")
        #expect(session.engine.glyphs.first?.standing == .confirmed)
    }

    @Test func terminfoAttributeResetAroundTheEchoStillConfirms() {
        // xterm-family terminfo spells sgr0 as `ESC ( B ESC [ m`.
        var session = armedSession()
        session.type("s")
        session.remote("\u{1B}(B\u{1B}[ms")

        #expect(session.drawn == "s")
        #expect(session.engine.glyphs.first?.standing == .confirmed)
    }

    @Test func shellIntegrationMarkersDoNotEndTheRun() {
        // cmux's shell integration emits OSC 133 and OSC 7 constantly; they
        // carry no grid content.
        var session = armedSession()
        session.type("s")
        session.remote("\u{1B}]133;C\u{7}s")

        #expect(session.engine.glyphs.first?.standing == .confirmed)
    }
}

extension TerminalPredictionEngineTests {
    @Test func nothingDrawnMeansNoDeadlineToWatch() {
        var session = armedSession()
        #expect(session.engine.nextExpiry == nil)

        session.type("s")
        #expect(session.engine.nextExpiry != nil)

        session.remote("x")
        #expect(session.engine.nextExpiry == nil)
    }

    @Test func theDeadlineIsTheOldestGlyphAndMovesInOnConfirmation() {
        var session = armedSession()
        session.type("s", after: .milliseconds(10))
        let typedAt = session.clock
        session.type("t", after: .milliseconds(10))

        // The speculative lifetime of the first glyph, not the second.
        #expect(session.engine.nextExpiry == typedAt + .milliseconds(1500))

        session.remote("s", after: .milliseconds(70))
        // A confirmed glyph waits on the shorter presentation hold instead.
        #expect(session.engine.nextExpiry == session.clock + .milliseconds(120))
    }

    @Test func aGlyphTheHostNeverTicksStillHasADeadlineToTickAt() throws {
        // The case this exists for: the link dies mid-line, so no output and
        // no frame ever arrives to drive a withdrawal.
        var session = armedSession()
        session.type("s")
        let deadline = try #require(session.engine.nextExpiry)

        session.clock = deadline + .milliseconds(1)
        session.engine.tick(at: session.clock)
        #expect(session.drawn == "")
    }
}

/// Backspace over glyphs the remote has not echoed yet.
///
/// The remote still receives, and echoes, every keystroke: the character,
/// then its erase. The overlay drops the glyph at once, and the engine has to
/// read that later echo as the confirmation it is rather than as output it
/// did not predict.
extension TerminalPredictionEngineTests {
    private static let backspace = "\u{7F}"

    @Test func backspaceRetractsAnUnconfirmedGlyph() {
        var session = armedSession()
        session.type("s")
        session.type("a")
        #expect(session.drawn == "sa")

        session.type(Self.backspace)
        #expect(session.drawn == "s")
        #expect(session.liveOffsets == [0])
        #expect(session.engine.status(at: session.clock) == .predicting)

        // Typing continues in the cell the retracted glyph gave back.
        session.type("d")
        #expect(session.drawn == "sd")
        #expect(session.liveOffsets == [0, 1])
    }

    @Test func eitherBackspaceByteRetracts() {
        // Ghostty sends DEL by default and BS when configured to.
        for input in ["\u{7F}", "\u{8}"] {
            var session = armedSession()
            session.type("s")
            session.type("a")
            session.type(input)
            #expect(session.drawn == "s")
            #expect(session.engine.status(at: session.clock) == .predicting)
        }
    }

    @Test func theLateEchoOfARetractedGlyphConfirmsWithoutWithdrawing() {
        var session = armedSession()
        session.type("s")
        session.type("a")
        session.type(Self.backspace)

        session.remote("s")
        #expect(session.drawn == "s")
        #expect(session.liveOffsets == [-1])

        // The remote prints the retracted "a" before it erases it. That cell
        // is the grid's to paint; the overlay must not bring the glyph back.
        // Each echo lands inside the hold of the confirmed "s".
        session.remote("a", after: .milliseconds(10))
        #expect(session.drawn == "s")
        #expect(session.liveOffsets == [-2])

        session.remote("\u{8} \u{8}", after: .milliseconds(10))
        #expect(session.drawn == "s")
        #expect(session.liveOffsets == [-1])
        #expect(session.engine.status(at: session.clock) == .predicting)

        // Still armed: the next keystroke predicts, and its echo confirms.
        session.type("d")
        #expect(session.drawn == "sd")
        #expect(session.liveOffsets == [-1, 0])
        session.remote("d", after: .milliseconds(10))
        #expect(session.engine.glyphs.map(\.standing) == [.confirmed, .confirmed])
        #expect(session.liveOffsets == [-2, -1])
    }

    @Test func anEraseSplitAcrossReadsKeepsOffsetsOnTheLiveCursor() {
        var session = armedSession()
        session.type("s")
        session.type("a")
        session.type(Self.backspace)
        session.remote("sa")
        #expect(session.liveOffsets == [-2])

        session.remote("\u{8}", after: .milliseconds(1))
        #expect(session.liveOffsets == [-1])
        session.remote(" ", after: .milliseconds(1))
        #expect(session.liveOffsets == [-2])
        session.remote("\u{8}", after: .milliseconds(1))
        #expect(session.liveOffsets == [-1])
        #expect(session.drawn == "s")
        #expect(session.engine.status(at: session.clock) == .predicting)
    }

    @Test func everyCommonEraseFormConfirmsTheRetraction() {
        // Tty canonical echo, readline, zsh's line editor, and the forms a
        // terminfo with delete-character or cursor-left emits.
        let erases = [
            "\u{8} \u{8}",
            "\u{8}\u{1B}[K",
            "\u{8}\u{1B}[0K",
            "\u{8}\u{1B}[P",
            "\u{8}\u{1B}[1P",
            "\u{1B}[D\u{1B}[K",
            "\u{1B}[1D\u{1B}[K",
            "\u{1B}[1D\u{1B}[P",
        ]
        for erase in erases {
            var session = armedSession()
            session.type("s")
            session.type("a")
            session.type(Self.backspace)
            session.remote("sa" + erase)

            #expect(session.drawn == "s", "\(Array(erase.utf8))")
            #expect(session.liveOffsets == [-1], "\(Array(erase.utf8))")
            #expect(
                session.engine.status(at: session.clock) == .predicting,
                "\(Array(erase.utf8))"
            )
        }
    }

    @Test func syntaxHighlightingAroundAnEraseStillConfirms() {
        var session = armedSession()
        session.type("s")
        session.type("a")
        session.type(Self.backspace)
        session.remote("s\u{1B}[31ma\u{1B}[0m\u{8}\u{1B}[K\u{1B}[32m")

        #expect(session.drawn == "s")
        #expect(session.engine.status(at: session.clock) == .predicting)
    }

    @Test func retractingEveryGlyphThenRetypingKeepsTheRun() {
        var session = armedSession()
        session.type("s")
        session.type("a")
        session.type(Self.backspace)
        session.type(Self.backspace)
        #expect(session.drawn == "")

        session.type("b")
        #expect(session.drawn == "b")
        #expect(session.liveOffsets == [0])

        // The erases arrive innermost first, as the remote processed them.
        session.remote("sa\u{8} \u{8}\u{8} \u{8}b")
        #expect(session.drawn == "b")
        #expect(session.engine.glyphs.map(\.standing) == [.confirmed])
        #expect(session.liveOffsets == [-1])
        #expect(session.engine.status(at: session.clock) == .predicting)
    }

    @Test func backspaceOverConfirmedTextWithdraws() {
        // The remote has already drawn "s" and a frame painted it, so erasing
        // it is the remote's business: behave as before and withdraw.
        var session = armedSession()
        session.type("s")
        session.remote("s")
        session.engine.presentedFrame(at: session.clock)
        #expect(session.drawn == "")

        session.type(Self.backspace)
        #expect(session.drawn == "")
        #expect(session.engine.status(at: session.clock) == .listening)
    }

    @Test func backspaceOverAnEchoNotYetPaintedBlanksItUntilTheErase() {
        // The echo of "s" arrived but no frame has painted it: the overlay
        // still holds it. Dropping it would show a blank, then the grid's
        // "s" for a frame, then the erase. It is blanked instead.
        var session = armedSession()
        session.type("s")
        session.remote("s")
        #expect(session.engine.glyphs.map(\.standing) == [.confirmed])

        session.type(Self.backspace)
        #expect(session.drawn == "")
        #expect(session.blanks == [-1])
        #expect(session.engine.status(at: session.clock) == .predicting)

        // The erase lands; the blank stays until a frame shows it.
        session.remote("\u{8}\u{1B}[K")
        #expect(session.engine.holdsLayoutUntilFrame)
        session.engine.presentedFrame(at: session.clock)
        #expect(session.engine.glyphs.isEmpty)
        #expect(!session.engine.holdsLayoutUntilFrame)
    }

    @Test func aLayoutHoldWithNoFrameReleasesAfterTheConfirmationHold() {
        // A host that never reports presented frames (ghostty's IOSurface
        // layer skips the drawable hook frames are counted on) must not keep
        // the overlay frozen on the blanks the erase removed.
        var session = armedSession()
        session.type("s")
        session.type(Self.backspace)
        session.remote("s")
        session.remote("\u{8}\u{1B}[K")
        #expect(session.engine.holdsLayoutUntilFrame)
        let held = session.clock
        #expect(session.engine.nextExpiry == held + .milliseconds(120))

        let changedEarly = session.engine.tick(at: held + .milliseconds(100))
        #expect(!changedEarly)
        #expect(session.engine.holdsLayoutUntilFrame)
        let changedAfter = session.engine.tick(at: held + .milliseconds(121))
        #expect(changedAfter)
        #expect(!session.engine.holdsLayoutUntilFrame)
        #expect(session.engine.nextExpiry == nil)
    }

    @Test func backspaceOnAnEmptyLineWithdraws() {
        var session = armedSession()
        session.advance(.milliseconds(5))
        session.engine.presentedFrame(at: session.clock)
        #expect(session.drawn == "")

        session.type(Self.backspace)
        #expect(session.engine.status(at: session.clock) == .listening)

        session.type("s")
        #expect(session.drawn == "")
    }

    @Test func backspaceAtAPasswordPromptShowsNothing() {
        var session = armedSession()
        session.remote("\r\n[sudo] password for leo: ")

        for character in ["h", "u", "n", Self.backspace, "t", "e", Self.backspace, "r", "2"] {
            session.type(character)
            #expect(session.drawn == "")
        }
        #expect(session.engine.status(at: session.clock) == .listening)
    }

    @Test func unexpectedOutputAfterARetractionWithdraws() {
        // Anything but the character and one of the recognised erases means
        // the remote is not a line editor doing what we modelled.
        let outcomes = [
            // A different character where the retracted one was expected.
            "sx",
            // The erase with no echo of the character first.
            "s\u{8} \u{8}",
            // A redraw of the whole line.
            "sa\r\u{1B}[K$ s",
            // Two cells erased for one keystroke.
            "sa\u{1B}[2D\u{1B}[K",
            // An erase that stops halfway and prints something else.
            "sa\u{8}x",
        ]
        for outcome in outcomes {
            var session = armedSession()
            session.type("s")
            session.type("a")
            session.type(Self.backspace)
            session.type("d")
            #expect(session.drawn == "sd")

            session.remote(outcome)
            #expect(session.drawn == "", "\(Array(outcome.utf8))")
            #expect(
                session.engine.status(at: session.clock) == .listening,
                "\(Array(outcome.utf8))"
            )
        }
    }

    @Test func aRemoteBackspaceWithNothingRetractedStillWithdraws() {
        // Moving back over echoed text is fine as long as the remote prints
        // it again; printing something else there is a redraw.
        var session = armedSession()
        session.type("s")
        session.remote("\u{8}x")
        #expect(session.drawn == "")
        #expect(session.engine.status(at: session.clock) == .listening)
    }

    @Test func anUndrawnEraseStillSetsTheDeadlineForWhatIsDrawn() throws {
        // The erase is what expires first, and expiring it withdraws "d".
        // A deadline read off drawn glyphs alone would leave "d" drawn at an
        // offset that assumes the erase, a second past when it gave up.
        var session = armedSession()
        session.type("s")
        session.type("a")
        session.type(Self.backspace)
        let erasedAt = session.clock
        session.remote("sa")
        session.type("d", after: .seconds(1))
        #expect(session.drawn == "d")

        let deadline = try #require(session.engine.nextExpiry)
        #expect(deadline == erasedAt + .milliseconds(1500))

        session.clock = deadline + .milliseconds(1)
        session.engine.tick(at: session.clock)
        #expect(session.drawn == "")
    }

    @Test func unmodelledErasesDoNotSuspendPrediction() {
        // A shell that repaints the whole line on Backspace is doing nothing
        // wrong; withdrawing is enough, and counting it would suspend
        // prediction after a few corrections.
        var session = armedSession()
        for _ in 0..<6 {
            session.type("s")
            session.type("a")
            session.type(Self.backspace)
            #expect(session.drawn == "s")
            session.remote("sa\r\u{1B}[K$ s")
            #expect(session.drawn == "")
            #expect(session.engine.status(at: session.clock) != .suspended)
            // Re-arm for the next cycle, once the dropped keystrokes' echo
            // could no longer be in flight.
            session.advance(.milliseconds(300))
            session.type("l")
            session.remote("l")
            session.type("l")
            session.remote("l")
            session.advance(.milliseconds(5))
            session.engine.presentedFrame(at: session.clock)
        }
        #expect(session.engine.status(at: session.clock) == .predicting)
    }

    @Test func anEchoThatMovesTheCursorUnderADrawnGlyphAsksForARedraw() {
        // "a" goes out before the run arms, so it is never drawn; "b" is.
        // The echo of "a" changes nothing drawn but moves the cursor "b" is
        // measured from, and the host re-anchors only when asked.
        var session = Session()
        session.type("k")
        session.remote("k")
        session.type("l")
        session.type("a", after: .milliseconds(5))
        session.remote("l")
        session.type("b", after: .milliseconds(5))
        #expect(session.liveOffsets == [1])

        session.advance(.milliseconds(10))
        let redraw = session.engine.observedOutput(Array("a".utf8), at: session.clock)
        #expect(redraw)
        #expect(session.liveOffsets == [0])
    }

    @Test func anEraseTheRemoteNeverSendsIsWithdrawn() {
        var session = armedSession()
        session.type("s")
        session.type("a")
        session.type(Self.backspace)
        session.remote("sa")
        session.type("d", after: .milliseconds(1))
        #expect(session.drawn == "sd")

        session.advance(.milliseconds(1501))
        session.engine.tick(at: session.clock)
        #expect(session.drawn == "")
    }
}
