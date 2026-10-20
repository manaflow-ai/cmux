@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// Chrome's per-tab omnibox focus (u2573): a browser tab left while its
/// address bar had the keyboard gets the address bar back on return; a
/// click into its page does not.
@Suite struct OmnibarFocusMemoryTests {
    let bar = FocusState.Resolved.addressBar(pane: "p1", tab: "a")
    let pageA = FocusState.Resolved.browserPage(pane: "p1", tab: "a")
    let pageB = FocusState.Resolved.browserPage(pane: "p1", tab: "b")
    let terminal = FocusState.Resolved.terminal(pane: "p2", tab: "t")

    @Test func returningToTheTabRestoresItsAddressBar() {
        var memory = OmnibarFocusMemory()
        #expect(!memory.note(.selectTab(pane: "p1", tab: "b", source: .keyboard), before: bar, after: pageB))
        #expect(memory.tabs == ["a"])
        #expect(memory.note(.selectTab(pane: "p1", tab: "a", source: .mouse), before: pageB, after: pageA))
        #expect(memory.tabs.isEmpty, "once")
    }

    @Test func aPaneSwitchBackRestoresItToo() {
        var memory = OmnibarFocusMemory()
        _ = memory.note(.focusPane("p2", source: .mouse), before: bar, after: terminal)
        #expect(memory.note(.focusPane("p1", source: .keyboard), before: terminal, after: pageA))
    }

    /// A click in the page (a responder report) is the user's choice: the
    /// memory is dropped, nothing is restored.
    @Test func aClickInThePageForgetsIt() {
        var memory = OmnibarFocusMemory()
        _ = memory.note(.focusPane("p2", source: .mouse), before: bar, after: terminal)
        #expect(!memory.note(.responder(.content(pane: "p1"), source: .mouse), before: terminal, after: pageA))
        #expect(memory.tabs.isEmpty)
    }

    /// Leaving the bar for the same tab's page (Enter, Escape) is not leaving the tab.
    @Test func enterOnTheSameTabRemembersNothing() {
        var memory = OmnibarFocusMemory()
        #expect(!memory.note(.focusPane("p1", source: .programmatic), before: bar, after: pageA))
        #expect(memory.tabs.isEmpty)
    }
}
