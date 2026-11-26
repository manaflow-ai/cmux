import Foundation
import Testing

@testable import CmuxAgentChat

/// OSC 133 marks, written with explicit escapes so the fixtures read like the
/// real PTY bytes. ESC = \u{1b}, BEL = \u{07}.
@Suite("OSC133CommandParser")
struct OSC133CommandParserTests {
    private func esc(_ body: String) -> String { "\u{1b}]\(body)\u{07}" }
    private func mark(_ k: String) -> String { esc("133;\(k)") }

    @Test("a complete command/output/exit cycle yields one finished block")
    func happyPath() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + "user@host$ " + mark("B") + "echo hi" + mark("C") + "hi\n" + mark("D;0"))
        #expect(parser.blocks.count == 1)
        let block = parser.blocks[0]
        #expect(block.command == "echo hi")
        #expect(block.output == "hi\n")
        #expect(block.exitCode == 0)
        #expect(block.isRunning == false)
        #expect(block.failed == false)
    }

    @Test("a nonzero exit code marks the block failed")
    func failure() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "false" + mark("C") + mark("D;1"))
        #expect(parser.blocks[0].exitCode == 1)
        #expect(parser.blocks[0].failed)
    }

    @Test("a block with no D mark stays running until the next prompt closes it")
    func runningUntilNextPrompt() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "sleep 5" + mark("C") + "working")
        #expect(parser.blocks.count == 1)
        #expect(parser.blocks[0].isRunning)
        #expect(parser.blocks[0].output == "working")
        // A new prompt (e.g. after Ctrl-C) closes the open block.
        parser.consume(mark("A"))
        #expect(parser.blocks[0].isRunning == false)
        #expect(parser.blocks[0].exitCode == nil)
    }

    @Test("two commands produce two blocks with distinct ids")
    func twoCommands() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "ls" + mark("C") + "a b\n" + mark("D;0"))
        parser.consume(mark("A") + mark("B") + "pwd" + mark("C") + "/tmp\n" + mark("D;0"))
        #expect(parser.blocks.count == 2)
        #expect(parser.blocks[0].command == "ls")
        #expect(parser.blocks[1].command == "pwd")
        #expect(parser.blocks[0].id != parser.blocks[1].id)
    }

    @Test("an escape sequence split across chunks is parsed once completed")
    func splitEscape() {
        var parser = OSC133CommandParser()
        let full = mark("A") + mark("B") + "id" + mark("C") + "uid=0\n" + mark("D;0")
        let mid = full.index(full.startIndex, offsetBy: 3)
        parser.consume(String(full[..<mid]))
        parser.consume(String(full[mid...]))
        #expect(parser.blocks.count == 1)
        #expect(parser.blocks[0].command == "id")
        #expect(parser.blocks[0].output == "uid=0\n")
        #expect(parser.blocks[0].exitCode == 0)
    }

    @Test("streaming output updates the running block incrementally")
    func streaming() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "build" + mark("C"))
        parser.consume("step 1\n")
        #expect(parser.blocks[0].output == "step 1\n")
        parser.consume("step 2\n")
        #expect(parser.blocks[0].output == "step 1\nstep 2\n")
        #expect(parser.blocks[0].isRunning)
        parser.consume(mark("D;0"))
        #expect(parser.blocks[0].isRunning == false)
    }

    @Test("carriage-return progress redraws fold to the final per-line state")
    func carriageReturnFold() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "dl" + mark("C") + "10%\r50%\r100%\n" + mark("D;0"))
        #expect(parser.blocks[0].output == "100%\n")
    }

    @Test("entering the alt screen flags the running block interactive")
    func altScreen() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "vim" + mark("C") + "\u{1b}[?1049h")
        #expect(parser.blocks[0].isInteractive)
    }

    @Test("non-133 OSC and CSI sequences are stripped from output")
    func stripsOtherSequences() {
        var parser = OSC133CommandParser()
        // OSC 0 (window title) + SGR color around the text.
        let noise = "\u{1b}]0;my title\u{07}" + "\u{1b}[31mred\u{1b}[0m"
        parser.consume(mark("A") + mark("B") + "x" + mark("C") + noise + "\n" + mark("D;0"))
        #expect(parser.blocks[0].output == "red\n")
    }

    @Test("CRLF line endings are preserved, not blanked")
    func crlfPreserved() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "x" + mark("C") + "line1\r\nline2\r\n" + mark("D;0"))
        #expect(parser.blocks[0].output == "line1\nline2\n")
    }

    @Test("a CR progress redraw still folds even with surrounding CRLF lines")
    func crlfAndProgressMix() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "x" + mark("C") + "start\r\n10%\r99%\r100%\r\ndone\r\n" + mark("D;0"))
        #expect(parser.blocks[0].output == "start\n100%\ndone\n")
    }

    @Test("alt screen batched with other private modes is still detected")
    func batchedAltScreen() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "tmux" + mark("C") + "\u{1b}[?1049;2004h")
        #expect(parser.blocks[0].isInteractive)
    }

    @Test("an unterminated OSC does not hang and the parser resyncs after it")
    func unterminatedOSCResyncs() {
        var parser = OSC133CommandParser()
        // A title OSC with no terminator, far longer than the escape cap.
        let junk = "\u{1b}]0;" + String(repeating: "x", count: 9000)
        parser.consume(mark("A") + mark("B") + "echo" + mark("C") + junk)
        // It must not crash/hang; then a real D still closes the block.
        parser.consume(mark("D;0"))
        #expect(parser.blocks.count == 1)
        #expect(parser.blocks[0].exitCode == 0)
        #expect(parser.blocks[0].isRunning == false)
    }

    @Test("large output is folded once and parses correctly")
    func largeOutput() {
        var parser = OSC133CommandParser()
        let big = (1...2000).map { "line \($0)" }.joined(separator: "\n")
        parser.consume(mark("A") + mark("B") + "seq" + mark("C") + big + "\n" + mark("D;0"))
        #expect(parser.blocks[0].output == big + "\n")
        #expect(parser.blocks[0].exitCode == 0)
    }

    @Test("a CRLF split across consume chunks is not blanked")
    func crlfSplitAcrossChunks() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "x" + mark("C") + "ab\r")
        // mid-stream the open line looks cleared, but the bytes are retained
        parser.consume("\ncd\r\n" + mark("D;0"))
        #expect(parser.blocks[0].output == "ab\ncd\n")
    }

    @Test("output fed one character at a time parses identically (incremental fold)")
    func byteAtATimeStreaming() {
        var parser = OSC133CommandParser()
        let full = mark("A") + mark("B") + "run" + mark("C")
            + "start\r\n10%\r99%\r100%\r\ndone\r\n" + mark("D;0")
        for char in full {
            parser.consume(String(char))
        }
        #expect(parser.blocks.count == 1)
        #expect(parser.blocks[0].command == "run")
        #expect(parser.blocks[0].output == "start\n100%\ndone\n")
        #expect(parser.blocks[0].exitCode == 0)
    }

    @Test("a bare prompt with no command yields an empty command string")
    func bareCommand() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + mark("C") + mark("D;0"))
        #expect(parser.blocks[0].command.isEmpty)
        #expect(parser.blocks[0].output.isEmpty)
    }
}
