import Foundation
import Testing
@testable import CmuxMobileTerminal

/// The launch marks' first key: one printable key sent, echoed as text in a batch, parsed,
/// then presented; once per tracker.
@Suite struct TerminalFirstEchoTests {
    @Test func marksTheFirstKeyAndItsEchoFrameOnce() {
        var echo = TerminalFirstEcho()
        // Evaluate mutations before #expect: its captured receiver is immutable.
        let beforeInput = echo.presented()
        #expect(!beforeInput, "no key yet: no echo frame")
        let returnSent = echo.sent(Data([0x0D]))
        #expect(!returnSent, "Return alone is not a probed key")
        let firstKeySent = echo.sent(Data("x".utf8))
        #expect(firstKeySent)
        let secondKeySent = echo.sent(Data("y".utf8))
        #expect(!secondKeySent, "only the first key")
        echo.fed(Data("prompt% ".utf8))
        echo.processed()
        let unrelatedFrame = echo.presented()
        #expect(!unrelatedFrame, "a batch without the key is not its echo")
        echo.fed(Data("x".utf8))
        let beforeParse = echo.presented()
        #expect(!beforeParse, "fed but not parsed yet")
        echo.processed()
        let echoFrame = echo.presented()
        #expect(echoFrame)
        #expect(echo.step == .done)
        let laterFrame = echo.presented()
        #expect(!laterFrame, "the echo frame is marked once")
        let laterKeySent = echo.sent(Data("z".utf8))
        #expect(!laterKeySent, "nothing after the first key")
    }

    @Test func probesOnlyASinglePrintableKey() {
        var echo = TerminalFirstEcho()
        let pasted = echo.sent(Data("x\r".utf8))
        #expect(!pasted, "a paste or a key with Return is not one key")
        let arrow = echo.sent(Data("\u{1B}[A".utf8))
        #expect(!arrow, "an escape sequence is not a printable key")
        let space = echo.sent(Data(" ".utf8))
        #expect(!space, "a space has no glyph to see")
        let key = echo.sent(Data("~".utf8))
        #expect(key)
    }

    @Test func ignoresTheKeysByteInsideEscapeSequences() {
        var echo = TerminalFirstEcho()
        _ = echo.sent(Data("~".utf8))
        // CSI with `~` as its final byte, an OSC title with `~` ended by BEL, a DCS
        // with `~` ended by ESC \, then one split across batches.
        echo.fed(Data("\u{1B}[2~\u{1B}]0;~/src\u{07}\u{1B}P~\u{1B}\\".utf8))
        echo.fed(Data("\u{1B}[3".utf8))
        echo.fed(Data("~".utf8))
        echo.processed()
        let controlFrame = echo.presented()
        #expect(!controlFrame, "a control sequence's `~` is not the echo")
        echo.fed(Data("\u{1B}[0m~".utf8))
        echo.processed()
        let echoFrame = echo.presented()
        #expect(echoFrame, "the `~` after the sequence is text")
    }

    @Test func outputBeforeTheKeyIsNotItsEcho() {
        var echo = TerminalFirstEcho()
        echo.fed(Data("~ % ".utf8))
        echo.processed()
        let promptFrame = echo.presented()
        #expect(!promptFrame, "the prompt's `~` came before any key")
        _ = echo.sent(Data("~".utf8))
        echo.processed()
        let staleFrame = echo.presented()
        #expect(!staleFrame, "no batch since the key")
    }
}
