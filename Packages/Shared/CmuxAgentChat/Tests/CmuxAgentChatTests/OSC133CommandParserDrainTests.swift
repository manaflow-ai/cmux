import Foundation
import Testing

@testable import CmuxAgentChat

/// `takeCompletedBlocks()` lets a long-lived consumer (per-tab command-history
/// recording) drain finished commands and bound memory while a command may
/// still be streaming.
@Suite("OSC133CommandParser.takeCompletedBlocks")
struct OSC133CommandParserDrainTests {
    private func esc(_ body: String) -> String { "\u{1b}]\(body)\u{07}" }
    private func mark(_ k: String) -> String { esc("133;\(k)") }

    @Test("drains finished blocks and empties when nothing is open")
    func drainsFinished() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "ls" + mark("C") + "out\n" + mark("D;0"))
        parser.consume(mark("A") + mark("B") + "pwd" + mark("C") + "/tmp\n" + mark("D;0"))

        let drained = parser.takeCompletedBlocks()
        #expect(drained.map(\.command) == ["ls", "pwd"])
        #expect(parser.blocks.isEmpty)
    }

    @Test("keeps the still-open block and continues streaming into it")
    func keepsOpenBlock() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "ls" + mark("C") + "a\n" + mark("D;0"))
        parser.consume(mark("A") + mark("B") + "sleep 5" + mark("C") + "work")

        let drained = parser.takeCompletedBlocks()
        #expect(drained.map(\.command) == ["ls"])
        #expect(parser.blocks.count == 1)
        #expect(parser.blocks[0].command == "sleep 5")
        #expect(parser.blocks[0].isRunning)

        // More output for the kept-open block still lands on it…
        parser.consume("ing\n" + mark("D;0"))
        #expect(parser.blocks[0].output == "working\n")
        #expect(parser.blocks[0].isRunning == false)
    }

    @Test("ids stay unique across drains")
    func idsStayUniqueAcrossDrains() {
        var parser = OSC133CommandParser()
        parser.consume(mark("A") + mark("B") + "one" + mark("C") + mark("D;0"))
        let first = parser.takeCompletedBlocks()

        parser.consume(mark("A") + mark("B") + "two" + mark("C") + mark("D;0"))
        let second = parser.takeCompletedBlocks()

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0].id != second[0].id)
    }

    @Test("draining an empty parser returns nothing")
    func drainEmpty() {
        var parser = OSC133CommandParser()
        #expect(parser.takeCompletedBlocks().isEmpty)
    }
}
