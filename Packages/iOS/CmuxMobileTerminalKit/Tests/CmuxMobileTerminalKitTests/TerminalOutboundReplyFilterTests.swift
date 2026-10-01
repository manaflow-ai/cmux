import CmuxMobileTerminalKit
import Foundation
import Testing

struct TerminalOutboundReplyFilterTests {
    private func filtered(_ text: String) -> String {
        String(decoding: Data(text.utf8).removingTerminalQueryReplies, as: UTF8.self)
    }

    @Test(arguments: [
        "\u{1B}[?62;22c",                 // DA1
        "\u{1B}[>1;10;0c",                // DA2
        "\u{1B}[12;40R",                  // CPR
        "\u{1B}[0n",                      // DSR ok
        "\u{1B}[?2004;1$y",               // DECRPM
        "\u{1B}[8;24;80t",                // window size report
        "\u{1B}]11;rgb:0000/0000/0000\u{07}", // OSC 11 reply (BEL)
        "\u{1B}]10;rgb:ffff/ffff/ffff\u{1B}\\", // OSC 10 reply (ST)
        "\u{1B}P>|ghostty 1.2\u{1B}\\",   // XTVERSION (DCS)
    ])
    func dropsQueryReplies(reply: String) {
        #expect(filtered(reply) == "")
    }

    @Test(arguments: [
        "\u{1B}[<0;12;5M",   // SGR mouse press
        "\u{1B}[<64;12;5M",  // SGR wheel
        "\u{1B}[I",          // focus in
        "\u{1B}[O",          // focus out
        "\u{1B}[A",          // alternate-scroll arrow
        "\u{1B}OB",          // SS3 arrow
        "\u{1B}[R",          // unmodified F3
        "ls -la\r",
    ])
    func keepsInput(input: String) {
        #expect(filtered(input) == input)
    }

    @Test func keepsInputAroundRepliesInOneWrite() {
        #expect(filtered("a\u{1B}[?62;22cb\u{1B}[<0;1;1Mc\u{1B}]11;rgb:1/2/3\u{07}d") == "ab\u{1B}[<0;1;1Mcd")
    }
}
