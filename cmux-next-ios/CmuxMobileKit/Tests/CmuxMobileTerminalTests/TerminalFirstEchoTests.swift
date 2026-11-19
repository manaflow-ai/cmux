import Foundation
import Testing
@testable import CmuxMobileTerminal

/// The launch marks' first key: sent, echoed in a batch, parsed, then presented; once per process.
@Suite struct TerminalFirstEchoTests {
    @Test func marksTheFirstKeyAndItsEchoFrameOnce() {
        var echo = TerminalFirstEcho()
        // Evaluate mutations before #expect: its captured receiver is immutable.
        let beforeInput = echo.presented()
        #expect(!beforeInput, "no key yet: no echo frame")
        let returnSent = echo.sent(Data([0x0D]))
        #expect(!returnSent, "Return alone is not a probed key")
        let firstKeySent = echo.sent(Data("x\r".utf8))
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
}
