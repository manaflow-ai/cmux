import Testing
@testable import CmuxTerminalPrediction

/// Drives the engine the way the host does: keystrokes in, PTY bytes back.
private struct Session {
    var engine = TerminalPredictionEngine(isEnabled: true)
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

    var drawn: String {
        String(engine.glyphs.map(\.character))
    }
}

/// Reaches the state where the engine is willing to draw: one echoed
/// character over a link slow enough to be worth predicting.
private func armedSession() -> Session {
    var session = Session()
    session.type("l")
    session.remote("l")
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

    @Test func predictsOnceTheEchoRunIsEstablished() {
        var session = armedSession()

        session.type("s")
        #expect(session.drawn == "s")
        #expect(session.engine.glyphs.first?.standing == .speculative)

        session.type("-")
        session.type("a")
        #expect(session.drawn == "s-a")
        #expect(session.engine.glyphs.map(\.offset) == [0, 1, 2])
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
        #expect(session.engine.glyphs.map(\.offset) == [0, 1])

        session.remote("a")
        session.advance(.milliseconds(5))
        session.engine.presentedFrame(at: session.clock)

        #expect(session.drawn == "b")
        #expect(session.engine.glyphs.map(\.offset) == [0])
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
        #expect(session.engine.glyphs.map(\.offset) == [-1, 0])
        #expect(session.engine.glyphs.map(\.standing) == [.confirmed, .speculative])

        session.remote("b", after: .milliseconds(1))
        #expect(session.engine.glyphs.map(\.offset) == [-2, -1])
    }

    @Test func keystrokesTypedBeforeArmingStillOccupyTheirCells() {
        // "a" and "b" go out before any echo, so neither is drawn. The echo
        // of "a" arms the run; "c" is then drawn, and has to land after the
        // cell "b" is about to take rather than on top of it.
        var session = Session()
        session.type("a")
        session.type("b", after: .milliseconds(5))
        session.remote("a")
        #expect(session.drawn == "")

        session.type("c", after: .milliseconds(5))
        #expect(session.drawn == "c")
        #expect(session.engine.glyphs.map(\.offset) == [1])

        // "b" arrives: never drawn, so nothing is held, and "c" is now the
        // cell under the cursor.
        session.remote("b", after: .milliseconds(1))
        #expect(session.engine.glyphs.map(\.offset) == [0])
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

    @Test func editingKeysAndReturnWithdrawRatherThanGuess() {
        for input in ["\r", "\u{7F}", "\u{1B}[D", "\u{3}"] {
            var session = armedSession()
            session.type("s")
            #expect(session.drawn == "s")

            session.type(input)
            #expect(session.drawn == "")
        }
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

    @Test func aFastLinkIsLeftAlone() {
        var session = Session()
        session.type("l")
        session.remote("l", after: .milliseconds(2))

        #expect(session.engine.status(at: session.clock) == .linkIsFastEnough)
        session.type("s")
        #expect(session.drawn == "")
    }

    @Test func slowEchoMeasurementDrivesTheDecisionToPredict() {
        var session = Session()
        session.type("l")
        session.remote("l", after: .milliseconds(70))

        #expect(session.engine.observedEchoLatency == .milliseconds(70))
        #expect(session.engine.status(at: session.clock) == .predicting)
    }

    @Test func repeatedVisibleWithdrawalsSuspendPrediction() {
        var session = armedSession()

        for _ in 0..<4 {
            session.type("s")
            #expect(session.drawn == "s")
            session.remote("x")
            // Re-arm for the next cycle.
            session.type("l")
            session.remote("l")
        }

        #expect(session.engine.status(at: session.clock) == .suspended)
        session.type("s")
        #expect(session.drawn == "")

        session.advance(.seconds(31))
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
