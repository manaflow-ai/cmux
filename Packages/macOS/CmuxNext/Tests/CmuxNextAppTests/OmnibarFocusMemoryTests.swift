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
        let restored1 = memory.note(.selectTab(pane: "p1", tab: "b", source: .keyboard), before: bar, after: pageB)
        #expect(!restored1)
        #expect(memory.tabs == ["a"])
        let restored2 = memory.note(.selectTab(pane: "p1", tab: "a", source: .mouse), before: pageB, after: pageA)
        #expect(restored2)
        #expect(memory.tabs.isEmpty, "once")
        // Its address-bar request is the return, once: a later identical request (Cmd-L) is not.
        let first = memory.takeReturn(OmnibarFocusMemory.returnEvent)
        let second = memory.takeReturn(OmnibarFocusMemory.returnEvent)
        #expect(first)
        #expect(!second)
    }

    @Test func aPaneSwitchBackRestoresItToo() {
        var memory = OmnibarFocusMemory()
        _ = memory.note(.focusPane("p2", source: .mouse), before: bar, after: terminal)
        let restored3 = memory.note(.focusPane("p1", source: .keyboard), before: terminal, after: pageA)
        #expect(restored3)
    }

    /// A click in the page (a responder report) is the user's choice: the
    /// memory is dropped, nothing is restored.
    @Test func aClickInThePageForgetsIt() {
        var memory = OmnibarFocusMemory()
        _ = memory.note(.focusPane("p2", source: .mouse), before: bar, after: terminal)
        let restored4 = memory.note(.responder(.content(pane: "p1"), source: .mouse), before: terminal, after: pageA)
        #expect(!restored4)
        #expect(memory.tabs.isEmpty)
    }

    /// Leaving the bar for the same tab's page (Enter, Escape) is not leaving the tab.
    @Test func enterOnTheSameTabRemembersNothing() {
        var memory = OmnibarFocusMemory()
        let restored5 = memory.note(.focusPane("p1", source: .programmatic), before: bar, after: pageA)
        #expect(!restored5)
        #expect(memory.tabs.isEmpty)
    }
}
