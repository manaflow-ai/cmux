import Testing
@testable import CmuxTerminalPrediction

/// The engine's offsets assume ghostty's parser has applied every byte the
/// engine has drained ("the tee runs ahead of the parser, and the engine
/// drains after it"). In the fork, `Termio.processOutput` calls the tee and
/// only then takes `renderer_state.mutex`, while the host's
/// `ghostty_surface_grid_metrics` read takes it with `lockDemand`. So the
/// main-actor drain can run, and re-anchor, before the IO thread parses the
/// same read. `presentedFrame` then retires held glyphs on a frame built
/// before the parse.
struct PredictionBreakRenderRaceTests {
    private func script() -> RigScript {
        var script = RigScript(roundTripMilliseconds: 120)
        script.arm()
        script.type("echo.hello", gapMilliseconds: 70)
        return script
    }

    @Test func withTheParserFirstNothingIsDrawnOverOtherText() {
        var rig = PredictionBreakRig(keystrokes: script().keystrokes)
        rig.run()
        #expect(rig.everDrewSpeculative)
        #expect(rig.wrongText.isEmpty, "\(rig.wrongText.prefix(5))")
    }

    /// The drain wins by 3 ms, less than one frame.
    @Test
    func aDrainThatBeatsTheParserDrawsEchoedGlyphsOverTheCellsToTheirLeft() {
        var rig = PredictionBreakRig(keystrokes: script().keystrokes)
        rig.parseLagMicros = 3_000
        rig.run()
        #expect(rig.wrongText.isEmpty, Comment(rawValue: rig.wrongText.prefix(6).joined(separator: "\n")))
    }

    /// A frame presented between the drain and the parse retires the held
    /// glyph, and that frame does not contain its character yet.
    @Test
    func aFrameBetweenDrainAndParseBlanksAnEchoedCharacter() {
        var rig = PredictionBreakRig(keystrokes: script().keystrokes)
        rig.parseLagMicros = 20_000
        rig.run()
        #expect(rig.blankings.isEmpty, Comment(rawValue: rig.blankings.prefix(6).joined(separator: "\n")))
    }
}
