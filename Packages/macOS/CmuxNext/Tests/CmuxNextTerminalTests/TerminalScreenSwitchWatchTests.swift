@testable import CmuxNextTerminal
import Foundation
import Testing

/// RESIZE P0 15 review P2 2 and 3 (#38206 at 17154838e7b): the output lane reads Ghostty's alternate screen only after a
/// chunk that can switch it (``TerminalScreenSwitchWatch``), and the resize hold waits only while that read says a
/// full-screen program draws the screen. A switch whose bytes were split by the PTY read, or a read that failed, must
/// still be read, or the hold stays off (or on) for a screen that switched.
@Suite struct TerminalScreenSwitchWatchTests {
    /// A private mode set cut after ESC `[` `?` or inside its parameters is read after the chunk that finishes it, also
    /// when that chunk has no ESC of its own. Before, only a chunk end at ESC or ESC `[` was carried, so `1049h` alone
    /// read nothing and the lane kept the primary screen.
    @Test(arguments: [
        ["text \u{1B}[?", "1049h"],
        ["text \u{1B}[?10", "49h"],
        ["\u{1B}[", "?1049h"],
        ["\u{1B}", "[?1049h"],
        ["\u{1B}[?", "10", "49h"],
        ["\u{1B}", "[", "?1049h"],
    ])
    func aScreenSwitchSplitAcrossChunksIsReadAfterTheChunkThatEndsIt(_ chunks: [String]) {
        var watch = TerminalScreenSwitchWatch()
        for chunk in chunks.dropLast() { _ = watch.needsRead(after: Data(chunk.utf8)) }
        let read = watch.needsRead(after: Data(chunks.last!.utf8))
        #expect(read, "\(chunks.map(\.debugDescription)): the chunk that ends the switch is not read")
    }

    /// A read Ghostty could not do (an unlocked grid's resize in flight) is done after the next chunk, whatever it holds;
    /// one read that works ends it. Before, the switch was lost until the program sent another ESC `[` `?`.
    @Test func aFailedReadIsDoneAgainAfterTheNextChunk() {
        var watch = TerminalScreenSwitchWatch()
        let first = watch.needsRead(after: Data("\u{1B}[?1049h".utf8))
        #expect(first)
        watch.readFinished(false)
        let again = watch.needsRead(after: Data("plain".utf8))
        #expect(again, "a failed read was not done again")
        watch.readFinished(true)
        let after = watch.needsRead(after: Data("plain".utf8))
        #expect(!after, "a read that worked still asks for reads")
    }

    /// The cost rule: output that cannot switch the screen costs no read, also when an ordinary escape (SGR) is split.
    @Test func outputThatCannotSwitchTheScreenIsNotRead() {
        var watch = TerminalScreenSwitchWatch()
        // `needsRead` is mutating: #expect cannot call it on its captured copy, so each result is taken first.
        let plain = watch.needsRead(after: Data("hello world 123".utf8))
        let splitSGR = watch.needsRead(after: Data("red \u{1B}[3".utf8))
        let sgrEnd = watch.needsRead(after: Data("1mtext\u{1B}[0m".utf8))
        let text = watch.needsRead(after: Data("[?1049h is text here".utf8))
        #expect(!plain)
        #expect(!splitSGR)
        #expect(!sgrEnd)
        #expect(!text)
        let restore = watch.needsRead(after: nil)
        #expect(restore, "a snapshot restore is always read")
    }
}
