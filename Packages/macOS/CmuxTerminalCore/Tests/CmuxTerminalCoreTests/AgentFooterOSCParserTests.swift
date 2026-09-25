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
}
