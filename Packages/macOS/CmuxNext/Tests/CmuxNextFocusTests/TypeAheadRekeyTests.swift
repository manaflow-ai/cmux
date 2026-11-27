import CmuxNextFocus
import Testing

/// Keys typed right after the + button opened a New Tab page reach its field, also when the page's
/// tab gets its store id while they wait (cmux-lawrence-2, 2026-11-12: "hello" typed at once left
/// "hell" or "o", about one try in 60). The page shows under a provisional id (`pending_tab_…`);
/// the daemon's reply renames it, focus settles on the new id, and the queue took that for a focus
/// move and dropped its text.
@Suite struct TypeAheadRekeyTests {
    static let waiting = TypeAheadWait(focus: .agentPage(pane: "pane_a", tab: "pending_tab_1"), page: "readiness-1")

    /// The same page under its store id: the keys still go to it.
    @Test func keysSurviveTheTabsStoreID() {
        #expect(Self.waiting.survives(.agentPage(pane: "pane_a", tab: "tab_1"), page: "readiness-1"))
    }

    /// Focus on the same tab: nothing moved.
    @Test func keysSurviveTheSameFocus() {
        #expect(Self.waiting.survives(.agentPage(pane: "pane_a", tab: "pending_tab_1"), page: "readiness-1"))
    }

    /// Another page in the pane (the person picked another tab): the keys are dropped.
    @Test func keysDropOnAnotherPage() {
        #expect(!Self.waiting.survives(.agentPage(pane: "pane_a", tab: "tab_2"), page: "readiness-2"))
    }

    /// Focus left the page for a terminal or the sidebar: the keys are dropped.
    @Test func keysDropWhenFocusLeavesThePage() {
        #expect(!Self.waiting.survives(.terminal(pane: "pane_b", tab: "tab_3"), page: nil))
        #expect(!Self.waiting.survives(.sidebar, page: nil))
    }

    /// Cmd-N's new workspace shows its New Tab page in a stand-in pane (`pane:<handle>`) until the daemon names the pane
    /// (`pane_…`). The keys typed between the two went to the queue for that page, and focus settling on the named
    /// pane dropped them (cmdn-typing bench with a timed probe, cmux23, 2026-11-20: 3 of 30 runs lost 6 or 7 keys,
    /// "hello w" each time). The same page under the pane's real id keeps them.
    @Test func keysSurviveTheStandInPanesRealID() {
        let typed = TypeAheadWait(focus: .agentPage(pane: "pane:6917529027641081902", tab: "tab_1"), page: "readiness-1")
        #expect(typed.survives(.agentPage(pane: "pane_57a5fd95", tab: "tab_1"), page: "readiness-1"))
        #expect(!typed.survives(.agentPage(pane: "pane_57a5fd95", tab: "tab_2"), page: "readiness-2"), "another page under the real id")
        #expect(!typed.survives(.terminal(pane: "pane_57a5fd95", tab: "tab_3"), page: nil), "a terminal under the real id")
    }

    /// The same page shown in another pane is another focus: the keys are dropped.
    @Test func keysDropInAnotherPane() {
        #expect(!Self.waiting.survives(.agentPage(pane: "pane_b", tab: "tab_1"), page: "readiness-1"))
    }
}
