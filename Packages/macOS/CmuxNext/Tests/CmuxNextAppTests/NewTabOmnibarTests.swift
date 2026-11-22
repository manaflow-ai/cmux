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

    /// A spare page whose omnibar was used is never recycled with its text (NewTabSparePool).
    @Test func escapeHandsTheKeyboardBackToThePagesFieldAndEditingTouchesThePage() {
        #expect(NewTabOmnibar.outcome(for: .didEndEditing(.cancel)) == .returnToPage)
        #expect(NewTabOmnibar.outcome(for: .didEndEditing(.blur)) == .none)
        #expect(NewTabOmnibar.outcome(for: .didBeginEditing) == .touch)
    }

    /// cx-e2aa decision (chief 2026-10-09): Cmd-L from any tab opens the New Tab page with the
    /// omnibar focused; on a New Tab page it focuses that page's omnibar; a browser keeps its own bar.
    @Test func focusLocationAlwaysEndsInAnOmnibar() {
        #expect(NewTabPage.locationTarget(showsBrowser: true, showsNewTabPage: false) == .browserAddressBar)
        #expect(NewTabPage.locationTarget(showsBrowser: false, showsNewTabPage: true) == .newTabOmnibar)
        #expect(NewTabPage.locationTarget(showsBrowser: false, showsNewTabPage: false) == .openNewTabWithOmnibar)
    }
}
