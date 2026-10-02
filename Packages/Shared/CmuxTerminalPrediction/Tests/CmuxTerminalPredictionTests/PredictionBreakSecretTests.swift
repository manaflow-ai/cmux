import Testing
@testable import CmuxTerminalPrediction

/// Drives one engine with explicit millisecond timestamps.
private struct Clocked {
    var engine = TerminalPredictionEngine(isEnabled: true, isRemoteSurface: true)
    mutating func key(_ text: String, at ms: Int) {
        if text == "\r" { engine.typed(printableASCII: nil, at: .milliseconds(ms)); return }
        for byte in text.utf8 { engine.typed(printableASCII: byte, at: .milliseconds(ms)) }
    }
    mutating func out(_ text: String, at ms: Int) {
        engine.observedOutput(Array(text.utf8), at: .milliseconds(ms))
    }
    mutating func frame(at ms: Int) { engine.presentedFrame(at: .milliseconds(ms)) }
    var drawn: String { String(engine.glyphs.filter { $0.standing == .speculative }.map(\.character)) }
    var status: TerminalPredictionEngine.Status { engine.status(at: .milliseconds(0)) }
}

struct PredictionBreakSecretTests {
    /// Type-ahead into a password prompt. `ssh host` (or `sudo`, `git push`
    /// over https) takes a moment to ask; meanwhile the tty is still in
    /// cooked mode, so it echoes the first key typed ahead. That echo arms the
    /// run. readpassphrase() then turns echo off (TCSAFLUSH) and prints its
    /// prompt, but every key typed between the arm and the prompt's arrival
    /// is drawn in clear, though the remote never shows it.
    @Test func typeAheadIntoAPasswordPromptIsNotDrawn() {
        var s = Clocked()
        // A slow link, measured: 200 ms round trip.
        s.key("l", at: 0); s.out("l", at: 200); s.frame(at: 210)
        s.key("\r", at: 1_000)
        s.out("\r\n", at: 1_200)  // the shell runs `ssh host`, which is connecting
        // 1.5 s later the user starts typing the password ahead of the prompt.
        s.key("h", at: 2_500)
        s.out("h", at: 2_700)     // cooked-mode tty echo: the run arms
        s.frame(at: 2_710)
        for (index, character) in "unter2".enumerated() {
            s.key(String(character), at: 2_720 + index * 40)
        }
        // ssh turned echo off at 2 650 remote time; its prompt is still in flight.
        #expect(s.drawn.isEmpty, "password characters drawn in clear before the prompt arrived: \"\(s.drawn)\"")
    }

    /// sudo with `pwfeedback`, npm/inquirer and most TUI prompts mask each
    /// key as `*`. A password character that is itself `*` matches its own
    /// masked echo, arms the run, and the characters after it are drawn in
    /// clear until the next mask comes back.
    @Test func aMaskedPromptNeverArmsOnTheMask() {
        var s = Clocked()
        s.key("l", at: 0); s.out("l", at: 200); s.frame(at: 210)
        s.key("\r", at: 1_000)
        s.out("\r\n[sudo] password for leo: ", at: 1_200)
        s.key("*", at: 2_000); s.out("*", at: 2_200); s.frame(at: 2_210)
        for (index, character) in "hunter2".enumerated() {
            s.key(String(character), at: 2_250 + index * 40)
        }
        #expect(s.drawn.isEmpty, "password characters drawn in clear: \"\(s.drawn)\"")
    }
}

struct PredictionBreakShellTests {
    /// fish, and zsh with zsh-autosuggestions, print the suggestion after
    /// every key in a dim colour and move the cursor back over it. The
    /// cursor move withdraws everything drawn as a misprediction, so a few
    /// commands suspend prediction for 30 s. fish does this by default.
    @Test func autosuggestionsDoNotSuspendPrediction() {
        var s = Clocked()
        s.key("x", at: 0); s.out("x", at: 150); s.frame(at: 160)
        s.key("\r", at: 400); s.out("\r\n> ", at: 550)
        var t = 1_300
        for (command, suggestion) in [("ls", "s -la"), ("cd", "d src"), ("git", "it status"), ("ls", "s -la"), ("cd", "d src")] {
            let bytes = Array(command)
            s.key(String(bytes[0]), at: t)
            s.out("\(bytes[0])\u{1B}[90m\(suggestion.dropFirst())\u{1B}[0m\u{1B}[\(suggestion.count - 1)D", at: t + 150)
            s.frame(at: t + 160)
            for (index, character) in bytes.dropFirst().enumerated() {
                s.key(String(character), at: t + 200 + index * 60)
            }
            t += 200 + bytes.count * 60
            s.out(String(bytes.dropFirst()), at: t + 150)
            s.key("\r", at: t + 300); s.out("\r\n> ", at: t + 450)
            t += 1_200
        }
        #expect(s.engine.status(at: .milliseconds(t)) != .suspended, "autosuggestions suspended prediction by \(t) ms")
    }

    /// tmux or screen with a status-line clock repaints it every second with
    /// a cursor save, move and restore. Each repaint withdraws what is drawn
    /// as a misprediction, and continuous typing never re-arms. (tmux also
    /// uses the alternate screen, which turns prediction off outright; this is
    /// the non-alternate-screen case: a shell prompt clock, `screen` with
    /// altscreen off, an async prompt segment.)
    @Test func aOneSecondStatusRepaintDoesNotStopPrediction() {
        var s = Clocked()
        s.key("x", at: 0); s.out("x", at: 150); s.frame(at: 160)
        var drawnKeys = 0
        var events: [(Int, Int, String)] = []
        for index in 0..<80 {
            let t = 1_000 + index * 110
            let character = String(Array("the quick brown fox jumps over the lazy dog ")[index % 44])
            events.append((t, 1, character))
            events.append((t + 150, 0, character))
        }
        for second in 1...9 {
            events.append((second * 1_000 + 500, 0, "\u{1B}7\u{1B}[24;70H12:0\(second)\u{1B}8"))
        }
        for (t, kind, text) in events.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
            if kind == 1 {
                s.key(text, at: t)
                if s.engine.glyphs.last.map({ $0.standing == .speculative }) == true { drawnKeys += 1 }
            } else {
                s.out(text, at: t)
            }
            s.frame(at: t + 8)
        }
        let finalStatus = s.engine.status(at: .milliseconds(10_000))
        #expect(drawnKeys > 40, "only \(drawnKeys)/80 keys drawn with a 1 s status repaint; status \(finalStatus)")
    }
}
