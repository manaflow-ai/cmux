import CmuxTerminalCore
import Testing

@Suite
struct TerminalPasteLineJoinTests {
    @Test func joinsACommandSplitAtWrapPoints() {
        let pasted = "sed -i '' 's/old/new/' \nconfig/tailnet-acl.json && cp \nconfig/tailnet-acl.json /tmp/acl.json\n"
        #expect(
            TerminalPasteLineJoin(pasted).joined
                == "sed -i '' 's/old/new/' config/tailnet-acl.json && cp config/tailnet-acl.json /tmp/acl.json"
        )
    }

    @Test func dropsBackslashContinuationsAndTheirIndent() {
        let pasted = "gh workflow run ci.yml \\\n  --repo owner/name \\\n  --ref main"
        #expect(TerminalPasteLineJoin(pasted).joined == "gh workflow run ci.yml --repo owner/name --ref main")
    }

    @Test func keepsAnEscapedTrailingBackslash() {
        #expect(TerminalPasteLineJoin("printf '%s' \\\\\necho done").joined == "printf '%s' \\\\ echo done")
    }

    @Test func handlesCarriageReturnLineEndingsAndBlankLines() {
        #expect(TerminalPasteLineJoin("echo one\r\n\r\n\techo two\recho three").joined == "echo one echo two echo three")
    }

    @Test func leavesASingleLineUnchangedApartFromOuterWhitespace() {
        #expect(TerminalPasteLineJoin("  ls -la  \n").joined == "ls -la")
        #expect(TerminalPasteLineJoin(" \n\t\n").joined == "")
    }

    @Test func spansMultipleLinesIgnoresTrailingAndBlankLines() {
        #expect(!TerminalPasteLineJoin("ls -la").spansMultipleLines)
        #expect(!TerminalPasteLineJoin("ls -la\n").spansMultipleLines)
        #expect(!TerminalPasteLineJoin("\n  ls -la\n\n").spansMultipleLines)
        #expect(TerminalPasteLineJoin("ls\n-la").spansMultipleLines)
        #expect(TerminalPasteLineJoin("ls \\\n-la").spansMultipleLines)
    }
}
