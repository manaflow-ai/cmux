import Testing
@testable import CmuxTerminalPrediction

/// Leo's report: type fast, then Backspace, and characters he deleted are
/// back on screen. The engine retracts a speculative glyph at once, but the
/// remote still echoes that character and erases it a round trip later, and
/// nothing covers its cell in between. Backspace, Ctrl-U or Ctrl-W over
/// anything the remote already echoed withdraws every glyph still in flight,
/// and each of those echoes back too.
struct PredictionBreakDeleteTests {
    private func run(_ script: RigScript) -> PredictionBreakRig {
        var rig = PredictionBreakRig(keystrokes: script.keystrokes)
        rig.run()
        return rig
    }

    private func expectNoResurrection(_ rig: PredictionBreakRig, _ label: String) {
        #expect(rig.everDrewSpeculative, "\(label): never predicted, so the case proves nothing")
        if !rig.resurrections.isEmpty {
            Issue.record(Comment(rawValue: """
            \(label): deleted text shown again for \(rig.resurrectedMicros / 1000) ms in total
            \(rig.resurrections.prefix(6).map(\.description).joined(separator: "\n"))
            """))
        }
    }

    /// 100 ms round trip. "s" is drawn at once and Backspace 40 ms later
    /// retracts it. The echo of "s" lands 60 ms after that and ghostty paints
    /// it; nothing covers it until the erase lands 40 ms later still.
    @Test func aRetractedGlyphIsNotPaintedAgainByItsOwnEcho() {
        var script = RigScript(roundTripMilliseconds: 100)
        script.arm()
        script.type("s")
        script.press(.backspace, gapMilliseconds: 40)
        expectNoResurrection(run(script), "type s, Backspace 40 ms later")
    }

    /// A 20-key burst at 30 ms a key over 250 ms, then Backspace held at
    /// key-repeat speed. The first Backspaces retract glyphs in flight; the
    /// one that reaches an echoed glyph withdraws the rest; every in-flight
    /// character then echoes back onto the line the user is deleting.
    @Test func holdingBackspaceAfterABurstDoesNotRegrowTheLine() {
        var script = RigScript(roundTripMilliseconds: 250)
        script.arm()
        script.type("abcdefghijklmnopqrst")
        script.hold(.backspace, count: 20, initialDelayMilliseconds: 60)
        expectNoResurrection(run(script), "20-key burst, hold Backspace")
    }

    /// Type, Backspace, retype while the first echo is still in flight.
    @Test func typeBackspaceRetypeMidFlight() {
        var script = RigScript(roundTripMilliseconds: 200)
        script.arm()
        script.type("gti")
        script.hold(.backspace, count: 2, initialDelayMilliseconds: 40)
        script.type("it", gapMilliseconds: 45)
        expectNoResurrection(run(script), "gti ⌫⌫ it")
    }

    @Test func ctrlUAfterABurstDoesNotBringTheBurstBack() {
        var script = RigScript(roundTripMilliseconds: 200)
        script.arm()
        script.type("git commit -m wip")
        script.press(.killLine, gapMilliseconds: 50)
        expectNoResurrection(run(script), "burst then Ctrl-U")
    }

    @Test func ctrlWAfterABurstDoesNotBringTheWordBack() {
        var script = RigScript(roundTripMilliseconds: 200)
        script.arm()
        script.type("git checkout mian")
        script.press(.killWord, gapMilliseconds: 50)
        expectNoResurrection(run(script), "burst then Ctrl-W")
    }

    /// Typing, a paste, more typing, then Backspace back across the paste.
    @Test func backspaceAcrossAPasteBoundary() {
        var script = RigScript(roundTripMilliseconds: 200)
        script.arm()
        script.type("echo ")
        script.press(.paste(Array("PASTED".utf8)), gapMilliseconds: 40)
        script.type("tail", gapMilliseconds: 40)
        script.hold(.backspace, count: 12, initialDelayMilliseconds: 80)
        expectNoResurrection(run(script), "type, paste, type, hold Backspace")
    }

    /// Backspace while earlier keystrokes are still unconfirmed, the mixed
    /// case: some retracted, the next one lands on an echoed glyph.
    @Test func backspaceWhileEarlierKeystrokesAreUnconfirmed() {
        var script = RigScript(roundTripMilliseconds: 150)
        script.arm()
        script.type("abcdef", gapMilliseconds: 40)
        script.hold(.backspace, count: 4, initialDelayMilliseconds: 20, repeatMilliseconds: 60)
        expectNoResurrection(run(script), "Backspace over a half-echoed burst")
    }

    /// The sweep behind the numbers in the report: 100 to 300 ms with
    /// ±25% jitter, bursts of 20 to 50 keys, held Backspace.
    @Test func sweepBurstsThenHeldBackspaceUnderJitter() {
        var failing = 0
        var total = 0
        var worstMicros = 0
        var worstLabel = ""
        for roundTrip in stride(from: 100, through: 300, by: 50) {
            for burst in [20, 35, 50] {
                for seed in UInt64(1)...8 {
                    var script = RigScript(
                        roundTripMilliseconds: roundTrip,
                        jitterMilliseconds: roundTrip / 4,
                        seed: seed &* 7919 &+ UInt64(burst)
                    )
                    script.arm()
                    var random = SimulationRandom(seed: seed)
                    for _ in 0..<burst {
                        let byte = Array("asdfjkl ".utf8).randomElement(using: &random)!
                        script.press(.character(byte), gapMilliseconds: Int.random(in: 25...60, using: &random))
                    }
                    script.hold(.backspace, count: burst, initialDelayMilliseconds: Int.random(in: 20...300, using: &random))
                    let rig = run(script)
                    total += 1
                    if !rig.resurrections.isEmpty {
                        failing += 1
                        if rig.resurrectedMicros > worstMicros {
                            worstMicros = rig.resurrectedMicros
                            worstLabel = "rtt \(roundTrip) ms, burst \(burst), seed \(seed): \(rig.resurrections.first!)"
                        }
                    }
                }
            }
        }
        #expect(failing == 0, "\(failing)/\(total) runs showed deleted text again; worst \(worstMicros / 1000) ms, \(worstLabel)")
    }
}

