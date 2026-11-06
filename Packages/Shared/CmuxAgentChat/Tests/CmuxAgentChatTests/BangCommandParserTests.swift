import Testing
@testable import CmuxAgentChat

struct BangCommandParserTests {
    @Test func escapedTrailingBackslashesDoNotConsumeFollowingProse() {
        let command = "! printf '%s\\n' " + String(repeating: "\\", count: 2)
        #expect(BangCommandParser.commands(in: command + "\nThen continue with the next step.") == [command])
    }

    @Test func ordinaryHereDocumentDoesNotStripTerminatorTabs() {
        let command = "! bash <<EOF\necho before\n\tEOF\necho after\nEOF"
        #expect(BangCommandParser.commands(in: command) == [command])
    }

    @Test func dashHereDocumentAcceptsATabIndentedTerminator() {
        let command = "! bash <<-EOF\n\techo before\n\tEOF"
        #expect(BangCommandParser.commands(in: command + "\nExplanatory prose.") == [command])
    }

    @Test func withholdsAnUnsupportedHereDocumentDelimiterInsteadOfUsingItsPrefix() {
        let command = "! bash <<END.DATA\necho before\nEND\necho after\nEND.DATA"
        #expect(BangCommandParser.commands(in: command) == [])
    }

    @Test func withholdsConcatenatedQuotedHereDocumentDelimiters() {
        let command = "! bash <<'END'X\necho before\nEND\necho after\nENDX"
        #expect(BangCommandParser.commands(in: command) == [])
    }

    @Test func withholdsUnsupportedShellGroupsAndUnclosedQuotedArguments() {
        #expect(BangCommandParser.commands(in: "! (echo first\necho second)") == [])
        #expect(BangCommandParser.commands(in: "! printf '%s' 'unfinished") == [])
    }

    @Test func quotedArgumentsPreserveRealNewlines() {
        let command = "! printf '%s\\n' 'first\nsecond'"
        #expect(BangCommandParser.commands(in: command) == [command])
    }

    @Test func quotedHereDocumentTextIsOnlyAnArgument() {
        let command = "! printf '%s\\n' '<<EOF'"
        #expect(BangCommandParser.commands(in: command) == [command])
    }

    @Test func preservesLongOriginalCommandWithoutDisplayLineBreaks() {
        let command = "! bash ~/Documents/Projects/" + String(repeating: "long-directory/", count: 16) + "scripts/migrate.sh"
        #expect(BangCommandParser.commands(in: "Run this:\n\(command)\n\nIt takes a while.") == [command])
    }

    @Test func extractsInlineCodeAndLabelledSuggestions() {
        let tick = "\u{60}"
        let text = "Run \(tick)! git status\(tick).\n- Migrations: ! bash ~/scripts/migrate.sh\n- ! pwd"
        #expect(BangCommandParser.commands(in: text) == ["! git status", "! bash ~/scripts/migrate.sh", "! pwd"])
    }

    @Test func ignoresOrdinaryExclamationAndShellConditions() {
        #expect(BangCommandParser.commands(in: "Hello! world\nif ! test -f file; then\n  echo 'not a command!'\n!\n") == [])
    }

    @Test func keepsBackslashContinuationsAndQuotedArguments() {
        let command = ["! bash " + "\\", "  '~/a directory/script.sh' " + "\\", "  --query 'select * from things where id != 2'"].joined(separator: "\n")
        #expect(BangCommandParser.commands(in: command) == [command])
    }

    @Test func preservesHereDocumentBodyAndDoesNotExtractItsBangLines() {
        let command = "! bash <<'SCRIPT'\necho 'keep this blank line'\n\n! false\nSCRIPT"
        #expect(BangCommandParser.commands(in: command + "\n! pwd") == [command, "! pwd"])
    }

    @Test func doesNotOfferAnUnfinishedHereDocument() {
        #expect(BangCommandParser.commands(in: "! bash <<'SCRIPT'\necho waiting\n") == [])
    }

    @Test func deduplicatesWithoutChangingCommandContents() {
        let command = "! printf '%s\\n' 'hello world'"
        #expect(BangCommandParser.commands(in: command + "\n" + command) == [command])
    }
}
