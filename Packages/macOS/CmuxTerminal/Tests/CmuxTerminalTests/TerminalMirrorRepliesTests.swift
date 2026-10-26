import Foundation
import Testing
import CmuxTerminal

@Suite struct TerminalMirrorRepliesTests {
    private func filtered(_ text: String) -> String {
        String(decoding: Data(text.utf8).removingTerminalMirrorReplies, as: UTF8.self)
    }

    @Test(arguments: [
        "\u{1B}[?62;22c",                       // DA1
        "\u{1B}[>1;10;0c",                      // DA2
        "\u{1B}[12;40R",                        // CPR
        "\u{1B}[?12;40;1R",                     // DECXCPR
        "\u{1B}[0n",                            // DSR
        "\u{1B}[?997;1n",                       // color scheme report
        "\u{1B}[?2004;1$y",                     // DECRPM
        "\u{1B}[8;24;80t",                      // window size report
        "\u{1B}[?1u",                           // Kitty keyboard flags
        "\u{1B}[I",                             // focus in
        "\u{1B}[O",                             // focus out
        "\u{1B}]11;rgb:1e1e/1e1e/1e1e\u{1B}\\", // OSC 11 (ST)
        "\u{1B}]10;rgb:ffff/ffff/ffff\u{07}",   // OSC 10 (BEL)
        "\u{1B}P>|ghostty 1.3\u{1B}\\",         // XTVERSION
        "\u{1B}P1$r0m\u{1B}\\",                 // DECRQSS
        "\u{1B}_Gi=1;OK\u{1B}\\",               // Kitty graphics
    ])
    func dropsReplies(reply: String) {
        #expect(filtered(reply) == "")
    }

    @Test(arguments: [
        "ls -la\r",
        "\u{1B}",                     // legacy Escape
        "\u{1B}[27u",                 // Kitty Escape
        "\u{1B}[13;2u",               // Kitty Shift+Enter
        "\u{1B}[A",                   // arrow
        "\u{1B}OA",                   // application-mode arrow
        "\u{1B}[1;5A",                // Ctrl+Up
        "\u{1B}[R",                   // unmodified F3
        "\u{1B}[Z",                   // Shift+Tab
        "\u{1B}[200~hi\u{1B}[201~",   // bracketed paste
        "\u{1B}[<0;12;5M",            // SGR mouse press
        "\u{1B}]",                    // Alt+] with no terminator
        "\u{1B}P",                    // Alt+Shift+P with no terminator
        "\u{1B}[",                    // Alt+[
        "é\u{1B}b",                   // UTF-8 and Alt+B
        "\u{1B}[200~\u{1B}]11;rgb:1/2/3\u{07}\u{1B}[I\u{1B}[201~", // pasted text that looks like replies
        "\u{1B}[200~\u{1B}[?62;22c",       // paste continuing in the next write
        String(repeating: "\u{1B}]x", count: 4_000), // many unterminated strings
    ])
    func keepsInput(input: String) {
        #expect(filtered(input) == input)
    }

    @Test func keepsInputAroundRepliesInOneWrite() {
        let write = "a\u{1B}[?62;22cb\u{1B}[<0;1;1Mc\u{1B}]11;rgb:1/2/3\u{07}d\u{1B}[Ie\u{1B}[27u"
        #expect(filtered(write) == "ab\u{1B}[<0;1;1Mcde\u{1B}[27u")
    }

    @Test func filtersRepliesAfterABracketedPasteEnds() {
        let write = "\u{1B}[200~\u{1B}[I\u{1B}[201~\u{1B}[I\u{1B}[?62;22cz"
        #expect(filtered(write) == "\u{1B}[200~\u{1B}[I\u{1B}[201~z")
    }
}
