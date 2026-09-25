import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Agent footer OSC parser")
struct AgentFooterOSCParserTests {
    @Test("Parses agent and context values terminated by BEL")
    func parsesBelTerminatedFooter() {
        var parser = AgentFooterOSCParser()
        let update = parser.consume(Data("\u{1B}]699; agent=claude ; context=34% \u{07}".utf8))

        #expect(update == AgentFooterState(agent: "claude", contextPercent: 34))
    }

    @Test("Parses a C1 ST terminated footer")
    func parsesC1STerminatedFooter() {
        var parser = AgentFooterOSCParser()
        let bytes = [0x1B, 0x5D, 0x36, 0x39, 0x39, 0x3B]
            + Array("agent=codex;context=12%".utf8)
            + [0x9C]
        let update = parser.consume(Data(bytes))

        #expect(update == AgentFooterState(agent: "codex", contextPercent: 12))
    }

    @Test("Carries a footer sequence across output chunks")
    func carriesSequenceAcrossChunks() {
        var parser = AgentFooterOSCParser()
        #expect(parser.consume(Data("\u{1B}]699;agent=codex;context=".utf8)) == nil)
        let update = parser.consume(Data("78%\u{1B}".utf8))
        #expect(update == nil)
        #expect(parser.consume(Data("\\".utf8)) == AgentFooterState(agent: "codex", contextPercent: 78))
    }

    @Test("An empty agent clears the footer")
    func emptyAgentClearsFooter() {
        var parser = AgentFooterOSCParser()
        let update = parser.consume(Data("\u{1B}]699;agent=\u{07}".utf8))

        #expect(update?.isEmpty == true)
    }

    @Test("Ignores unrelated OSC commands and invalid context percentages")
    func ignoresUnrelatedAndInvalidValues() {
        var parser = AgentFooterOSCParser()
        #expect(parser.consume(Data("\u{1B}]0;699;agent=wrong\u{07}".utf8)) == nil)
        #expect(parser.consume(Data("\u{1B}]699;agent=codex;context=101%\u{07}".utf8)) == nil)
    }

    @Test("Does not treat a UTF-8 continuation byte as a C1 OSC control")
    func preservesUTF8ContinuationBeforeFooter() {
        var parser = AgentFooterOSCParser()
        let text = "prefix”\u{1B}]699;agent=codex;context=10%\u{07}"

        #expect(parser.consume(Data(text.utf8)) == AgentFooterState(agent: "codex", contextPercent: 10))
    }

    @Test("Preserves UTF-8 continuation bytes inside the agent name")
    func preservesUTF8ContinuationInPayload() {
        var parser = AgentFooterOSCParser()
        let text = "\u{1B}]699;agent=curly“;context=10%\u{07}"

        #expect(parser.consume(Data(text.utf8)) == AgentFooterState(agent: "curly“", contextPercent: 10))
    }

    @Test("Resynchronizes a new OSC after an incomplete escape")
    func resynchronizesAfterIncompleteEscape() {
        var parser = AgentFooterOSCParser()
        let text = "\u{1B}]1;stale\u{1B}]699;agent=codex;context=10%\u{07}"

        #expect(parser.consume(Data(text.utf8)) == AgentFooterState(agent: "codex", contextPercent: 10))
    }
}
