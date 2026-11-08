import Foundation
import Testing
@testable import CmuxRemoteSession

/// Tests the screen/tmux window-title escape stripper used on mirrored `%output`.
/// A remote shell inside tmux (TERM=screen*/tmux*) sets its title with
/// `ESC k <title> ST`; cmux's xterm-style mirror surface would print the title text
/// otherwise (the `echoej` bug). The filter must drop the sequence, survive chunk
/// splits, and leave everything else byte-identical.
///
/// Assertions compare raw `Data` (not UTF-8-decoded strings): the filter is a
/// byte-stream transform, and `String(decoding:as:)` silently replaces invalid
/// UTF-8 — which would mask a byte-corruption regression instead of failing.
@Suite struct RemoteTmuxScreenTitleFilterTests {
    private func run(_ chunks: [String]) -> Data {
        var f = RemoteTmuxScreenTitleFilter()
        var out = Data()
        for c in chunks { out.append(f.filter(Data(c.utf8))) }
        return out
    }
    private func run(_ s: String) -> Data { run([s]) }

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private let ESC = "\u{1b}"

    @Test func stripsStTerminatedTitleBetweenText() {
        // The exact echoej repro: command output `ej` preceded by `ESC k echo ESC \`.
        let input = "\(ESC)kecho\(ESC)\\ej"
        #expect(run(input) == bytes("ej"))
    }

    @Test func belDoesNotTerminateTitleMatchingTmux() {
        // tmux/screen end `ESC k` only on ST (`ESC \`), never BEL. A BEL is swallowed
        // as title text and the title runs until ST — matching the remote's rendering.
        #expect(run("a\(ESC)kfoo\u{07}bar\(ESC)\\Z") == bytes("aZ"))  // ST ends it; BEL consumed
        #expect(run("a\(ESC)kfoo\u{07}bar") == bytes("a"))            // no ST: rest consumed
    }

    @Test func stripsMultipleTitlesAndKeepsSurroundingText() {
        // Prompt sets title to `~`, command sets it to `echo`, output is `ej`.
        let input = "\(ESC)k~\(ESC)\\prompt \(ESC)kecho\(ESC)\\ej\r\n"
        #expect(run(input) == bytes("prompt ej\r\n"))
    }

    @Test func survivesChunkSplitsAtEveryBoundary() {
        let full = "X\(ESC)kabc\(ESC)\\Y"
        let allBytes = Array(full.utf8)
        // Split the stream after each byte and confirm the result is always "XY".
        for cut in 1..<allBytes.count {
            var f = RemoteTmuxScreenTitleFilter()
            var out = Data()
            out.append(f.filter(Data(allBytes[0..<cut])))
            out.append(f.filter(Data(allBytes[cut...])))
            #expect(out == bytes("XY"), "split at \(cut)")
        }
    }

    @Test func preservesCsiAndOtherEscapes() {
        // Color SGR and cursor moves must pass through untouched.
        let input = "\(ESC)[32mgreen\(ESC)[0m\(ESC)[2J\(ESC)[H"
        #expect(run(input) == bytes(input))
    }

    @Test func preservesEscFollowedByNonK() {
        // `ESC \` (ST) on its own, and an OSC title, are not `ESC k` and pass through.
        #expect(run("\(ESC)\\done") == bytes("\(ESC)\\done"))
        #expect(run("\(ESC)]0;title\u{07}x") == bytes("\(ESC)]0;title\u{07}x"))
    }

    @Test func plainTextUnchanged() {
        #expect(run("echo \"ej\"\r\nej\r\n") == bytes("echo \"ej\"\r\nej\r\n"))
    }

    @Test func titleImmediatelyFollowedByMoreTitle() {
        #expect(run("\(ESC)ka\(ESC)\\\(ESC)kb\(ESC)\\Z") == bytes("Z"))
    }
}
