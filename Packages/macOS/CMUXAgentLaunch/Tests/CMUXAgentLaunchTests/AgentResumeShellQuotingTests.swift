@testable import CMUXAgentLaunch
import Foundation
import Testing

@Suite("AgentResumeShellQuoting")
struct AgentResumeShellQuotingTests {
    @Test("ASCII input uses single quote escaping")
    func asciiInputUsesSingleQuoteEscaping() {
        let value = "it's\nfine"
        let expected = "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"

        #expect(AgentResumeShellQuoting().singleQuoted(value) == expected)
    }

    @Test("Non-ASCII input uses printf octal command substitution")
    func nonASCIIInputUsesPrintfOctalCommandSubstitution() {
        let value = "cafe \u{00E9} \u{4E2D}"
        let octalBytes = value.utf8
            .map { String(format: #"\%03o"#, Int($0)) }
            .joined()
        let expected = #""$(printf '"# + octalBytes + #"')""#

        #expect(AgentResumeShellQuoting().singleQuoted(value) == expected)
    }
}
