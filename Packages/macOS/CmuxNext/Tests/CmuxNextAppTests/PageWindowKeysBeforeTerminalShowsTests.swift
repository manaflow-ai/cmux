import CmuxNextFocus
import Testing
@testable import CmuxNextApp

/// Smoke TIP RED 1910 (feat 87c359304617, cmux22) and 8f4ebd709a4b (cmux23): Cmd-N (a New Tab page, a Chromium page
/// window with the keys), then Ctrl-` (a new terminal tab), then typing at once: the key window was still the New Tab
/// page's CefNSWindow. While the new terminal's surface was not shown yet, `FocusEffectApplier.moveResponder` left the
/// page focused and its window key, so keys typed then went to a window the model no longer targeted. A target in the
/// cmux window takes the keys from any Chromium page as soon as it is the target, shown or not; only a page target keeps them.
struct PageWindowKeysBeforeTerminalShowsTests {
    @Test func aTerminalNotShownYetTakesTheKeysFromAChromiumPage() {
        #expect(!FocusEffectApplier.pageKeepsKeysUntilShown(.terminal(pane: "pane_a", tab: "tab_new")),
                "a page window keeps the keys while the model targets a terminal that is still on its way")
    }

    @Test func aHomeConversationNotShownYetTakesTheKeysFromAChromiumPage() {
        #expect(!FocusEffectApplier.pageKeepsKeysUntilShown(.conversation(pane: "pane_a", tab: "tab_home")))
    }

    @Test func aPageTargetKeepsThePageUntilItShows() {
        #expect(FocusEffectApplier.pageKeepsKeysUntilShown(.agentPage(pane: "pane_a", tab: "tab_new_tab")))
        #expect(FocusEffectApplier.pageKeepsKeysUntilShown(.page(pane: "pane_a", tab: "tab_page")))
        #expect(FocusEffectApplier.pageKeepsKeysUntilShown(.browserPage(pane: "pane_a", tab: "tab_web")))
    }
}
