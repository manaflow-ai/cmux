import Foundation
import Testing
@testable import CmuxNextApp

/// New Agent Chat drafts from the tab it was opened from (#16620).
@Suite struct AgentTabSeedTests {
    @Test func aTerminalSelectionIsFenced() {
        #expect(AgentTabSeed.terminalDraft(selection: "  make test\nFAIL x  \n") == "```\nmake test\nFAIL x\n```\n\n")
        // A fence longer than the selection's own backticks keeps it whole.
        #expect(AgentTabSeed.terminalDraft(selection: "a ```b``` c") == "````\na ```b``` c\n````\n\n")
    }

    @Test func noSelectionMeansNoDraft() {
        #expect(AgentTabSeed.terminalDraft(selection: nil) == nil)
        #expect(AgentTabSeed.terminalDraft(selection: " \n ") == nil)
    }

    @Test func aPageGivesItsTitleURLAndQuotedSelection() {
        let url = URL(string: "https://example.com/docs")
        #expect(AgentTabSeed.browserDraft(title: "Docs", url: url, selection: "one\n\ntwo")
            == "Docs\nhttps://example.com/docs\n\n> one\n>\n> two\n\n")
        #expect(AgentTabSeed.browserDraft(title: "Docs", url: url, selection: nil) == "Docs\nhttps://example.com/docs\n\n")
        // A title that is just the URL is said once.
        #expect(AgentTabSeed.browserDraft(title: "https://example.com/docs", url: url, selection: "") == "https://example.com/docs\n\n")
    }

    @Test func aBlankPageGivesNoDraft() {
        #expect(AgentTabSeed.browserDraft(title: nil, url: URL(string: "about:blank"), selection: nil) == nil)
        #expect(AgentTabSeed.browserDraft(title: "", url: nil, selection: "  ") == nil)
    }

    @Test func aLongSelectionIsCapped() {
        let draft = AgentTabSeed.terminalDraft(selection: String(repeating: "x", count: AgentTabSeed.selectionLimit + 50))
        #expect(draft?.contains(String(repeating: "x", count: AgentTabSeed.selectionLimit) + "…") == true)
        #expect(draft?.contains(String(repeating: "x", count: AgentTabSeed.selectionLimit + 1)) == false)
    }
}
