import Foundation
import Testing
@testable import CmuxMobileTerminal

/// The launch marks' first key: sent, echoed in a batch, parsed, then presented; once per process.
@Suite struct TerminalFirstEchoTests {
    @Test func marksTheFirstKeyAndItsEchoFrameOnce() {
        var echo = TerminalFirstEcho()
        #expect(!echo.presented(), "no key yet: no echo frame")
        #expect(!echo.sent(Data([0x0D])), "Return alone is not a probed key")
        #expect(echo.sent(Data("x\r".utf8)))
        #expect(!echo.sent(Data("y".utf8)), "only the first key")
        echo.fed(Data("prompt% ".utf8))
        echo.processed()
        #expect(!echo.presented(), "a batch without the key is not its echo")
        echo.fed(Data("x".utf8))
        #expect(!echo.presented(), "fed but not parsed yet")
        echo.processed()
        #expect(echo.presented())
        #expect(echo.step == .done)
        #expect(!echo.presented(), "the echo frame is marked once")
        #expect(!echo.sent(Data("z".utf8)), "nothing after the first key")
    }
}
