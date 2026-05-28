import Foundation
import Testing
@testable import GhosttyVT

@Test func canConstructAndDestroyEmulator() throws {
    // If the binary target failed to link or libghostty-vt isn't loadable
    // on this platform, `ghostty_terminal_new` won't even resolve. This
    // is the "is the wiring real" test.
    let term = try GhosttyTerminalEmulator(cols: 80, rows: 24)
    #expect(term.rawHandle != nil)
}

@Test func feedingBytesDoesNotCrash() throws {
    // Feed a representative mix: plain text, SGR, CRLF, autosuggest
    // ghost text styled with dim grey, then reset. We are not asserting
    // grid state here yet — the grid-ref Swift bridge lands in the next
    // step — only that the parser doesn't trap on bytes the Swift
    // parser used to mis-handle (CRLF row separators specifically).
    let term = try GhosttyTerminalEmulator(cols: 80, rows: 24)
    let dim = "\u{001B}[38;2;110;112;102m"
    let reset = "\u{001B}[0m"
    let viewport = [
        "echo aaa",
        "aaa",
        "echo bbb",
        "bbb",
        "lawrence \u{03BB} h\(dim)top\(reset)",
    ].joined(separator: "\r\n")
    term.write(string: viewport)
}

@Test func resizeUpdatesGrid() throws {
    let term = try GhosttyTerminalEmulator(cols: 80, rows: 24)
    try term.resize(cols: 120, rows: 40)
}
