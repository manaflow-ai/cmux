import CmuxTerminalCore
import Testing

@Suite
struct TerminalPasteLineJoinTests {
    @Test func joinsACommandSplitAtWrapPoints() {
        let pasted = "sed -i '' 's/old/new/' \nconfig/tailnet-acl.json && cp \nconfig/tailnet-acl.json /tmp/acl.json\n"
        #expect(
            TerminalPasteLineJoin.joined(pasted)
                == "sed -i '' 's/old/new/' config/tailnet-acl.json && cp config/tailnet-acl.json /tmp/acl.json"
        )
    }

    @Test func dropsBackslashContinuationsAndTheirIndent() {
        let pasted = "gh workflow run ci.yml \\\n  --repo owner/name \\\n  --ref main"
        #expect(TerminalPasteLineJoin.joined(pasted) == "gh workflow run ci.yml --repo owner/name --ref main")
    }

    @Test func keepsAnEscapedTrailingBackslash() {
        #expect(TerminalPasteLineJoin.joined("printf '%s' \\\\\necho done") == "printf '%s' \\\\ echo done")
    }

    @Test func handlesCarriageReturnLineEndingsAndBlankLines() {
        #expect(TerminalPasteLineJoin.joined("echo one\r\n\r\n\techo two\recho three") == "echo one echo two echo three")
    }

    @Test func leavesASingleLineUnchangedApartFromOuterWhitespace() {
        #expect(TerminalPasteLineJoin.joined("  ls -la  \n") == "ls -la")
        #expect(TerminalPasteLineJoin.joined(" \n\t\n") == "")
    }

    @Test func spansMultipleLinesIgnoresTrailingAndBlankLines() {
        #expect(!TerminalPasteLineJoin.spansMultipleLines("ls -la"))
        #expect(!TerminalPasteLineJoin.spansMultipleLines("ls -la\n"))
        #expect(!TerminalPasteLineJoin.spansMultipleLines("\n  ls -la\n\n"))
        #expect(TerminalPasteLineJoin.spansMultipleLines("ls\n-la"))
        #expect(TerminalPasteLineJoin.spansMultipleLines("ls \\\n-la"))
    }
}
