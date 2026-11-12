import Foundation
import Testing
@testable import CmuxTerminalPrediction

private struct Session {
    var engine = TerminalPredictionEngine(isEnabled: true, isRemoteSurface: true)
    var clock: Duration = .zero
    var visibleWithdrawals = 0

    mutating func at(_ milliseconds: Int) { clock = .milliseconds(milliseconds) }

    mutating func type(_ byte: UInt8?, at milliseconds: Int) {
        at(milliseconds)
        let drawnBefore = !engine.glyphs.isEmpty
        engine.typed(printableASCII: byte, at: clock)
        if drawnBefore, engine.glyphs.isEmpty, byte != nil { visibleWithdrawals += 1 }
    }

    mutating func remote(_ bytes: [UInt8], at milliseconds: Int) {
        at(milliseconds)
        engine.observedOutput(bytes, at: clock)
    }

    mutating func remote(_ text: String, at milliseconds: Int) {
        remote(Array(text.utf8), at: milliseconds)
    }

    var drawn: String { String(engine.glyphs.map(\.character)) }
}

struct PredictionBreakEngineTests {
    /// A 1.3 s link with ±400 ms jitter (a congested satellite or mobile link), the latency where prediction matters
    /// most. `speculativeLifetime` is a fixed 1.5 s, so every late echo
    /// withdraws what the user saw, counts as a misprediction, and four of
    /// them suspend prediction for 30 s.
    @Test func aSlowJitteryLinkKeepsPredicting() {
        var engine = TerminalPredictionEngine(isEnabled: true, isRemoteSurface: true)
        var random = SimulationRandom(seed: 42)
        var events: [(Int, Bool, UInt8)] = []  // (time ms, isEcho, byte)
        var typedAt = 0
        var lastEcho = 0
        let text = Array("git log --oneline --graph --decorate --all | head -40".utf8)
        for byte in text {
            typedAt += Int.random(in: 60...160, using: &random)
            let echo = max(lastEcho, typedAt + 1_300 + Int.random(in: -400...400, using: &random))
            lastEcho = echo
            events.append((typedAt, false, byte))
            events.append((echo, true, byte))
        }
        // Arm first: one echoed key well before.
        engine.typed(printableASCII: UInt8(ascii: "x"), at: .milliseconds(-3_000))
        engine.observedOutput([UInt8(ascii: "x")], at: .milliseconds(-1_800))
        engine.presentedFrame(at: .milliseconds(-1_790))
        var suspendedAt: Int?
        var withdrawnVisible = 0
        var drawnKeys = 0
        for (time, isEcho, byte) in events.sorted(by: { ($0.0, $0.1 ? 0 : 1) < ($1.0, $1.1 ? 0 : 1) }) {
            let now = PredictionInstant.milliseconds(time)
            let before = engine.glyphs.contains { $0.standing == .speculative }
            if isEcho {
                engine.observedOutput([byte], at: now)
            } else {
                engine.typed(printableASCII: byte, at: now)
                if engine.glyphs.last?.standing == .speculative, engine.glyphs.last?.offset == engine.glyphs.map(\.offset).max() {
                    drawnKeys += 1
                }
            }
            engine.presentedFrame(at: now + .milliseconds(8))
            if before, !engine.glyphs.contains(where: { $0.standing == .speculative }), !isEcho { withdrawnVisible += 1 }
            if suspendedAt == nil, engine.status(at: now) == .suspended { suspendedAt = time }
        }
        #expect(drawnKeys * 2 >= text.count, "only \(drawnKeys) of \(text.count) keys were drawn at typing time; \(withdrawnVisible) visible withdrawals")
        #expect(suspendedAt == nil, "suspended at \(suspendedAt.map { "\($0) ms" } ?? "-") after \(withdrawnVisible) visible withdrawals, over a link that never lost a byte")
    }

    /// zsh-syntax-highlighting recolours a word once it names a command:
    /// typing the "s" of "ls" makes zle move back over "l" and rewrite "ls"
    /// in the new colour. The move back withdraws the drawn "s" as a
    /// misprediction, so four commands in ten seconds suspend prediction for
    /// thirty.
    @Test func zshSyntaxHighlightingDoesNotSuspendPrediction() {
        var session = Session()
        session.type(UInt8(ascii: "x"), at: 0)
        session.remote("x", at: 150)
        session.type(0x0D, at: 400)  // Return withdraws
        session.remote("\r\n$ ", at: 550)
        var t = 1_000
        for command in ["ls", "cd", "ls", "vi", "ls", "cd"] {
            let bytes = Array(command.utf8)
            // First key: echoed red, no move.
            session.type(bytes[0], at: t)
            session.remote("\u{1B}[31m\(command.prefix(1))\u{1B}[39m", at: t + 150)
            t += 200
            // Second key completes a command: zle moves back one and rewrites.
            session.type(bytes[1], at: t)
            session.remote("\u{08}\u{1B}[32m\(command)\u{1B}[39m", at: t + 150)
            t += 200
            session.type(0x0D, at: t)
            session.remote("\r\n$ ", at: t + 150)
            t += 900
        }
        #expect(session.engine.status(at: session.clock) != .suspended, "zsh-syntax-highlighting suspended prediction by \(session.clock)")
    }

    /// A kitty graphics placement (APC) or a sixel image (DCS) moves the
    /// cursor, but the scanner classifies every string sequence as
    /// ignorable, so glyphs keep offsets measured from the old cursor and the
    /// host draws them wherever the image left it.
    @Test func anImageThatMovesTheCursorWithdrawsPredictions() {
        var session = Session()
        session.type(UInt8(ascii: "k"), at: 0)
        session.remote("k", at: 150)
        session.type(UInt8(ascii: "l"), at: 200)
        session.remote("l", at: 350)
        session.type(UInt8(ascii: "s"), at: 400)
        #expect(session.drawn == "s")
        // An async job (a prompt segment, `kitten icat` in the background)
        // places a 1x4-cell image at the cursor; kitty moves the cursor past it.
        session.remote("\u{1B}_Ga=T,f=100,c=4,r=1;iVBORw0KGgo=\u{1B}\\", at: 450)
        #expect(session.drawn == "", "'s' is still drawn after an image moved the cursor 4 cells")
        // Sixel: the cursor ends up below the image.
        var sixel = Session()
        sixel.type(UInt8(ascii: "k"), at: 0)
        sixel.remote("k", at: 150)
        sixel.type(UInt8(ascii: "l"), at: 200)
        sixel.remote("l", at: 350)
        sixel.type(UInt8(ascii: "s"), at: 400)
        sixel.remote("\u{1B}Pq#0;2;0;0;0#0~~~~-~~~~\u{1B}\\", at: 450)
        #expect(sixel.drawn == "", "'s' is still drawn after a sixel image moved the cursor")
    }
}

struct PredictionBreakLatencyTests {
    /// Typing steadily over a constant link, report how many keys were
    /// drawn when typed and whether prediction suspended itself.
    private func steadyTyping(roundTrip: Int, keys: Int = 60, gap: Int = 120) -> (drawn: Int, suspended: Bool) {
        var engine = TerminalPredictionEngine(isEnabled: true, isRemoteSurface: true)
        for (index, byte) in "xy".utf8.enumerated() {
            let typedAt = -10_000 + index * 3_000
            engine.typed(printableASCII: byte, at: .milliseconds(typedAt))
            engine.observedOutput([byte], at: .milliseconds(typedAt + roundTrip))
            engine.presentedFrame(at: .milliseconds(typedAt + roundTrip + 8))
        }
        var events: [(Int, Int, UInt8)] = []  // time, 0 = echo first, byte
        for index in 0..<keys {
            let byte = UInt8(ascii: "a") + UInt8(index % 26)
            events.append((index * gap, 1, byte))
            events.append((index * gap + roundTrip, 0, byte))
        }
        var drawn = 0
        var suspended = false
        for (time, kind, byte) in events.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
            let now = PredictionInstant.milliseconds(time)
            if kind == 0 {
                engine.observedOutput([byte], at: now)
            } else {
                engine.typed(printableASCII: byte, at: now)
                if engine.glyphs.contains(where: { $0.standing == .speculative && $0.character == Character(UnicodeScalar(byte)) }) { drawn += 1 }
            }
            engine.presentedFrame(at: now + .milliseconds(8))
            if engine.status(at: now) == .suspended { suspended = true }
        }
        return (drawn, suspended)
    }

    /// `speculativeLifetime` is a fixed 1.5 s. Past that round trip every
    /// keystroke expires before its echo arrives, so no echo ever matches,
    /// the run never arms, and the links that need prediction most get none.
    @Test func aRoundTripLongerThanTheLifetimeStillPredicts() {
        let result = steadyTyping(roundTrip: 1_600)
        #expect(result.drawn > 40 && !result.suspended, "1.6 s link: \(result.drawn)/60 drawn, suspended \(result.suspended)")
    }

    @Test func aSecondRoundTripPredictsEveryKey() {
        let result = steadyTyping(roundTrip: 1_000)
        #expect(result.drawn > 55, "1.0 s link: \(result.drawn)/60 drawn")
    }

    /// One late echo (a 2 s stall on a 300 ms link) withdraws. Every key
    /// typed within the untracked-echo window pushes the window out again,
    /// so while the user keeps typing, nothing is drawn for the rest of the
    /// line.
    @Test func oneStallDoesNotTurnPredictionOffUntilTheUserPauses() {
        var engine = TerminalPredictionEngine(isEnabled: true, isRemoteSurface: true)
        engine.typed(printableASCII: UInt8(ascii: "x"), at: .zero)
        engine.observedOutput([UInt8(ascii: "x")], at: .milliseconds(300))
        engine.presentedFrame(at: .milliseconds(308))
        var events: [(Int, Int, UInt8)] = []
        for index in 0..<40 {
            let typedAt = 1_000 + index * 120
            // The fifth key's echo stalls 2 s; everything behind it queues.
            let echoAt = index < 4 ? typedAt + 300 : max(1_000 + 4 * 120 + 2_300, typedAt + 300)
            events.append((typedAt, 1, UInt8(ascii: "a") + UInt8(index % 26)))
            events.append((echoAt, 0, UInt8(ascii: "a") + UInt8(index % 26)))
        }
        var drawnAfterStall = 0
        for (time, kind, byte) in events.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
            let now = PredictionInstant.milliseconds(time)
            if kind == 0 { engine.observedOutput([byte], at: now) } else {
                engine.typed(printableASCII: byte, at: now)
                if time > 4_500, engine.glyphs.contains(where: { $0.standing == .speculative }) { drawnAfterStall += 1 }
            }
            engine.presentedFrame(at: now + .milliseconds(8))
        }
        #expect(drawnAfterStall > 0, "no key typed after the stall cleared (from 3.8 s to 5.7 s) was drawn")
    }
}
