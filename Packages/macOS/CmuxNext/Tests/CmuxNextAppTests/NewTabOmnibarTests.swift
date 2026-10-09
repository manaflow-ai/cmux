import CmuxNextAgentPane
import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextApp

/// The New Tab page's omnibar (cx-e2aa, Lawrence 2026-10-09: "we should show the omnibar in new tab
/// page. so people can just cmd+l to explicitly do new tab"): what each omnibar boundary does.
struct NewTabOmnibarTests {
    @Test func aCommittedAddressReplacesThePageWithABrowserTab() {
        let url = URL(string: "https://cmux.dev/docs")!
        #expect(NewTabOmnibar.outcome(for: .didEndEditing(.commit(url)))
            == .open(AgentPaneOpenTab(kind: .browser, text: "https://cmux.dev/docs")))
    }

    @Test func aModifiedCommitAlsoOpensTheAddressFromThePage() {
        let url = URL(string: "https://cmux.dev/")!
        #expect(NewTabOmnibar.outcome(for: .didEndEditing(.open(url, .newForegroundTab)))
            == .open(AgentPaneOpenTab(kind: .browser, text: "https://cmux.dev/")))
    }

    @Test func aSwitchToTabRowRevealsThatTab() {
        #expect(NewTabOmnibar.outcome(for: .didEndEditing(.switchToTab(key: "tab-7"))) == .reveal("tab-7"))
    }

    @Test func escapeHandsTheKeyboardBackToThePagesField() {
        #expect(NewTabOmnibar.outcome(for: .didEndEditing(.cancel)) == .returnToPage)
        #expect(NewTabOmnibar.outcome(for: .didEndEditing(.blur)) == .none)
        #expect(NewTabOmnibar.outcome(for: .didBeginEditing) == .none)
    }
}
