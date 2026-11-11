import CmuxNextBridge
import Testing

/// Lawrence 2026-11-10: "tabs also follow Chrome's rule". The one close-selection rule for the tabs of a pane
/// (plans/cmux-next/close-focus.md, "One close-selection rule"), driven through the window's selection memory
/// and its rule state (`TabSelectionMemory.closeRule`), as a pane's strip drives them. The rows are the worked
/// cases and the two decisions of the hand-off file /work/wt/handoff/tasks/close-selection-rule.md (R0 to R5;
/// 14:02Z: a new tab right after the current one keeps its opener as a link's tab does, one at the end is the
/// quick look-up; 14:20Z: no group preference). It replaces the 2026-11-08 "always the tab before" rule
/// (#38316, #38328, #38419).
@MainActor
struct TabCloseSelectionTests {
    /// One pane's strip in one window: its tabs in strip order, and what the app tells the window's memory.
    @MainActor
    private final class Pane {
        let memory: TabSelectionMemory
        let id: String
        var tabs: [String]
        /// The members of a collapsed group.
        var hidden: Set<String> = []
        /// The tabs a pending close hides (the store's close intents, `DaemonStore.closingTabIDs`).
        var closing: Set<String> = []

        init(_ tabs: [String], selected: String, id: String = "pane", memory: TabSelectionMemory = TabSelectionMemory()) {
            (self.memory, self.id, self.tabs) = (memory, id, tabs)
            memory.select(selected, in: id)
            sync()
        }

        var selected: String? { memory.selection(in: id) }

        /// The pane's apply: the tab it shows for its tabs as they are now.
        @discardableResult
        func sync() -> String? { memory.resolve(pane: id, tabs: tabs, defaultIndex: 0, hidden: hidden, closing: { self.closing }) }

        /// A person's new tab (Cmd-T, the +), right after the selected tab, or at the end. `link`: a link's page that
        /// shows before its store tab exists (the GitHub page), right after the selected tab.
        func newTab(_ new: String, atEnd: Bool = false, link: Bool = false) {
            guard let current = selected, let index = tabs.firstIndex(of: current) else { return }
            memory.closeRule.expect(in: id, opener: current, listed: tabs, quick: atEnd, link: link)
            tabs.insert(new, at: atEnd ? tabs.count : index + 1)
            memory.selectMade(new, in: id, inPlaceOf: nil, tabs: tabs)
            sync()
        }

        /// A link in `opener` opens `new` in the background, right after `after`.
        func linkTab(_ new: String, from opener: String, after: String) {
            guard let index = tabs.firstIndex(of: after) else { return }
            tabs.insert(new, at: index + 1)
            memory.closeRule.made(new, from: opener, in: id, foreground: false)
            sync()
        }

        /// A script's new tab (the CLI, the socket, MCP) right after `after`, selected: no person made it.
        func scriptTab(_ new: String, after: String) {
            guard let index = tabs.firstIndex(of: after) else { return }
            tabs.insert(new, at: index + 1)
            memory.select(new, in: id)
            sync()
        }

        /// The person selects `tab` (a click, a shortcut, the palette).
        func click(_ tab: String) {
            memory.closeRule.personSelects(tab, in: id)
            memory.select(tab, in: id)
        }

        /// `closed` leave the pane (a close of any kind, or a move to another pane); returns the tab it shows then.
        @discardableResult
        func remove(_ closed: String...) -> String? {
            tabs.removeAll { closed.contains($0) }
            return sync()
        }

        /// The selection a close causes at its press, before its tabs leave (a tab group's close, `tabGroup.close`).
        /// `byPerson` false: the close came from the CLI or a script.
        func closeSelects(_ next: String, byPerson: Bool) {
            memory.closeRule.closeSelects(next, in: id)
            if byPerson { memory.closeRule.personSelects(next, in: id) }
            memory.select(next, in: id)
        }

        /// The press of a close of `tab`: a close intent hides it at once (a guarded close while the daemon's read
        /// decides, `HiddenTabClose`; any close until the daemon answers). Returns the tab the pane shows then.
        @discardableResult
        func press(_ tab: String) -> String? {
            closing.insert(tab)
            tabs.removeAll { $0 == tab }
            return sync()
        }

        /// The pending close of `tab` is cancelled or refused: it shows again at `index`. `selected`: the pane
        /// selects it again, as `TabCloseGuard`'s restore does for the tab it showed at the press.
        func cancel(_ tab: String, at index: Int, selected: Bool = true) {
            closing.remove(tab)
            tabs.insert(tab, at: index)
            sync()
            if selected { memory.select(tab, in: id) }
        }

        /// The pending close of `tab` is committed: the daemon's records dropped it.
        func commit(_ tab: String) {
            closing.remove(tab)
            sync()
        }
    }

    // MARK: A new tab right after the current one (the default): Chrome 156's observed middle-tab rows

    @Test func aNewTabClosedAtOnceReturnsToTheTabThePersonCameFrom() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.newTab("n")
        #expect(pane.tabs == ["a", "b", "n", "c", "d"])
        #expect(pane.remove("n") == "b")
        #expect(pane.memory.closeRule.isEmpty)
    }

    @Test func aVisitToItsOpenerAndBackStillReturnsToTheOpener() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.newTab("n")
        pane.click("b")
        pane.click("n")
        #expect(pane.remove("n") == "b")
    }

    @Test func aVisitToAnUnrelatedTabAndBackSelectsTheNextTab() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.newTab("n")
        pane.click("d")
        pane.click("n")
        #expect(pane.memory.closeRule.isEmpty)
        #expect(pane.remove("n") == "c")
    }

    /// Row 4 of the 14:02Z decision: B has two background link tabs, the new tab goes right of B and is closed at
    /// once: the first tab of its opener's family after it.
    @Test func aNewTabBesideItsOpenersLinkTabsReturnsToTheFirstOfThem() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.linkTab("l2", from: "b", after: "b")
        pane.linkTab("l4", from: "b", after: "l2")
        pane.newTab("n")
        #expect(pane.tabs == ["a", "b", "n", "l2", "l4", "c", "d"])
        #expect(pane.remove("n") == "l2")
    }

    /// The daemon's tab takes its stand-in's place, and what a New Tab page turns into takes the page's: one item.
    @Test func aTabThatTakesItsStandInsPlaceKeepsTheOpener() {
        let pane = Pane(["a", "b", "c"], selected: "b")
        pane.newTab("pending_tab_1")
        pane.tabs = ["a", "b", "n", "c"]
        pane.memory.selectMade("n", in: pane.id, inPlaceOf: nil, tabs: pane.tabs)
        #expect(pane.sync() == "n")
        pane.tabs = ["a", "b", "n", "t", "c"]
        pane.memory.selectMade("t", in: pane.id, inPlaceOf: "n", tabs: pane.tabs)
        pane.tabs = ["a", "b", "t", "c"]
        #expect(pane.sync() == "t")
        #expect(pane.remove("t") == "b")
    }

    // MARK: A new tab at the end: the quick look-up

    @Test func aNewTabAtTheEndClosedAtOnceReturnsToTheTabThePersonCameFrom() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.newTab("n", atEnd: true)
        #expect(pane.tabs == ["a", "b", "c", "d", "n"])
        #expect(pane.remove("n") == "b")
    }

    @Test func aQuickLookUpEndsWhenThePersonLeavesItsTab() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.newTab("n", atEnd: true)
        pane.click("b")
        pane.click("n")
        #expect(pane.remove("n") == "d")
    }

    /// The first typed navigation of a quick look-up tab keeps its opener; the next one starts another task.
    @Test func aTypedNavigationForgetsExceptTheFirstOfAQuickLookUp() {
        let quick = Pane(["a", "b", "c", "d"], selected: "b")
        quick.newTab("n", atEnd: true)
        quick.memory.closeRule.typedNavigation(in: "n", pane: quick.id)
        #expect(quick.memory.closeRule.isEmpty == false)
        quick.memory.closeRule.typedNavigation(in: "n", pane: quick.id)
        #expect(quick.remove("n") == "d")
        let kept = Pane(["a", "b", "c", "d"], selected: "b")
        kept.newTab("n", atEnd: true)
        kept.memory.closeRule.typedNavigation(in: "n", pane: kept.id)
        #expect(kept.remove("n") == "b")
        // A new tab in the middle is not Chrome's "new tab at the end of the strip": its first typed navigation forgets.
        let middle = Pane(["a", "b", "c", "d"], selected: "b")
        middle.newTab("n")
        middle.memory.closeRule.typedNavigation(in: "n", pane: middle.id)
        #expect(middle.remove("n") == "c")
    }

    // MARK: By position: the NEXT tab, the previous one only for the last

    @Test func aTabInTheMiddleSelectsTheNextAndTheLastThePrevious() {
        #expect(Pane(["a", "b", "c", "d"], selected: "b").remove("b") == "c")
        #expect(Pane(["a", "b", "c", "d"], selected: "d").remove("d") == "c")
        #expect(Pane(["a", "b", "c", "d"], selected: "a").remove("a") == "b")
    }

    @Test func closingATabThatIsNotSelectedKeepsTheSelection() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        #expect(pane.remove("c") == "b")
        pane.newTab("n")
        #expect(pane.remove("d") == "n")
        #expect(pane.remove("n") == "b")
    }

    /// With no opener relation held, a selection change keeps and reads nothing.
    @Test func aStripWithNoOpenerHoldsNoState() {
        let pane = Pane(["a", "b", "c"], selected: "a")
        pane.click("c")
        pane.click("b")
        #expect(pane.memory.closeRule.isEmpty)
        #expect(pane.remove("b") == "c")
    }

    // MARK: The link family

    @Test func theFirstOfTwoLinkTabsClosedSelectsItsSibling() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.linkTab("x", from: "b", after: "b")
        pane.linkTab("y", from: "b", after: "x")
        pane.click("x")
        #expect(pane.remove("x") == "y")
    }

    @Test func theOpenerClosedSelectsTheFirstTabItOpened() {
        let pane = Pane(["a", "b", "c"], selected: "b")
        pane.linkTab("x", from: "b", after: "b")
        pane.linkTab("y", from: "b", after: "x")
        #expect(pane.tabs == ["a", "b", "x", "y", "c"])
        #expect(pane.remove("b") == "x")
    }

    /// Observed on Chrome 156: B opens L2 in the background, the person goes to C, back to B, to L2, closes L2: B.
    @Test func movesBetweenTabsWithNoOpenerKeepALinkTabsOpener() {
        let pane = Pane(["a", "b", "c"], selected: "b")
        pane.linkTab("l2", from: "b", after: "b")
        pane.click("c")
        pane.click("b")
        pane.click("l2")
        #expect(pane.remove("l2") == "b")
    }

    /// The GitHub page a link opens shows before its store tab exists, so the pane's next selection gives it its
    /// opener. It is a link's foreground tab: the pane's older relations end at its open (Chromium: a foreground
    /// tab that takes an opener forgets the others first), so its close returns to the opener, not to the
    /// opener's older link tab.
    @Test func aLinksPageShownAtOnceReturnsToItsOpenerAndEndsThePanesOlderRelations() {
        let pane = Pane(["a", "b", "c"], selected: "a")
        pane.linkTab("l", from: "a", after: "a")
        pane.newTab("g", link: true)
        #expect(pane.tabs == ["a", "g", "l", "b", "c"])
        #expect(pane.selected == "g")
        // With the older relation alive the pick would be "l", the tab its opener opened before.
        #expect(pane.remove("g") == "a")
        #expect(pane.memory.closeRule.isEmpty)
    }

    // MARK: The press of a close keeps the relation; the committed close ends it

    /// A guarded close hides its tab at the press (`TabCloseGuard`, `HiddenTabClose`); a running program's question
    /// answered Cancel, or a close the daemon refuses, shows the tab again, selected. It keeps its opener, as a
    /// workspace does (`WorkspaceCloseReviewTests.aCancelledCloseKeepsTheOpener`). `atEnd`: the quick look-up.
    @Test(arguments: [false, true]) func aCancelledCloseKeepsTheOpener(atEnd: Bool) {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.newTab("n", atEnd: atEnd)
        let index = atEnd ? 4 : 2
        #expect(pane.press("n") == "b")
        #expect(pane.memory.closeRule.isEmpty == false)
        pane.cancel("n", at: index)
        #expect(pane.selected == "n")
        #expect(pane.tabs.firstIndex(of: "n") == index)
        // The close the person asks for again goes to the opener, not to the next tab.
        #expect(pane.press("n") == "b")
        pane.commit("n")
        #expect(pane.memory.closeRule.isEmpty)
    }

    /// The tab under a pending close was not the selected one (its close button): the selection stays, and the tab
    /// that comes back still returns to its opener.
    @Test func aCancelledCloseOfATabThatIsNotSelectedKeepsItsOpener() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.linkTab("l", from: "b", after: "b")
        #expect(pane.press("l") == "b")
        pane.cancel("l", at: 2, selected: false)
        pane.click("l")
        #expect(pane.remove("l") == "b")
    }

    /// The committed close ends the relations of its tab: a tab it opened takes its opener (R4).
    @Test func aCommittedCloseEndsTheRelationsOfItsTab() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.newTab("n")
        pane.linkTab("l", from: "n", after: "n")
        #expect(pane.tabs == ["a", "b", "n", "l", "c", "d"])
        #expect(pane.press("n") == "l")
        pane.commit("n")
        #expect(pane.remove("l") == "b")
        #expect(pane.memory.closeRule.isEmpty)
    }

    /// The pane's strip does not change when the daemon commits a close whose tab it already hid: the tab leaves
    /// the rule's state before the next pick of its pane, with no apply in between.
    @Test func aCommittedCloseIsKnownBeforeTheNextPickOfItsPane() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.newTab("n")
        pane.linkTab("l", from: "n", after: "n")
        #expect(pane.press("n") == "l")
        pane.closing = []
        #expect(pane.press("l") == "b")
        pane.closing = []
        pane.sync()
        #expect(pane.memory.closeRule.isEmpty)
    }

    /// A close's own selection is the close's only while it runs. A script's group close selects B at the press;
    /// much later the person selects B again from an unrelated tab: that is a gesture, and it ends the relations.
    @Test(arguments: [false, true]) func aClosesPickDoesNotOutliveItsClose(byPerson: Bool) {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.newTab("n")
        pane.closeSelects("b", byPerson: byPerson)
        #expect(pane.remove("n") == "b")
        pane.click("c")
        pane.newTab("m")
        #expect(pane.tabs == ["a", "b", "c", "m", "d"])
        pane.click("b") // unrelated to m: the person starts another task
        pane.click("c")
        pane.click("m")
        #expect(pane.remove("m") == "d")
    }

    // MARK: Nothing for automation, and a relation holds inside one pane

    @Test func aScriptsNewTabHasNoOpener() {
        let pane = Pane(["a", "b", "c", "d"], selected: "b")
        pane.scriptTab("n", after: "b")
        #expect(pane.memory.closeRule.isEmpty)
        #expect(pane.remove("n") == "c")
    }

    @Test func aTabMovedToAnotherPaneForgetsItsRelations() {
        let memory = TabSelectionMemory()
        let pane = Pane(["a", "b", "c", "d"], selected: "b", memory: memory)
        let other = Pane(["p", "q"], selected: "p", id: "other", memory: memory)
        pane.newTab("n")
        // The opener moves away: the new tab has none left.
        #expect(pane.remove("b") == "n")
        other.tabs = ["p", "b", "q"]
        other.sync()
        #expect(memory.closeRule.isEmpty)
        #expect(pane.remove("n") == "c")
        // The new tab itself moves away: it gets no opener in the pane it lands in.
        let from = Pane(["a", "b", "c"], selected: "b", id: "from", memory: memory)
        from.newTab("m")
        #expect(from.remove("m") == "b")
        other.tabs = ["p", "m", "b", "q"]
        memory.select("m", in: other.id)
        other.sync()
        #expect(other.remove("m") == "b")
        #expect(memory.closeRule.isEmpty)
    }

    // MARK: Close Others, Close to the Left and Close to the Right keep their rule; collapsed groups

    /// Each of the three selects the tab the person acted on, which stays (#38419, cmux-ad i7), and then closes
    /// the others: a selection that survives stays, whatever the opener relations say.
    @Test func closeOthersLeftAndRightKeepTheTabThePersonActedOn() {
        let others = Pane(["a", "b", "c", "d"], selected: "b")
        others.newTab("n")
        others.memory.select("c", in: others.id) // Close Other Tabs on c: its handler selects c
        #expect(others.remove("a", "b", "n", "d") == "c")
        let right = Pane(["a", "b", "c", "d"], selected: "d")
        right.memory.select("b", in: right.id) // Close Tabs to the Right of b
        #expect(right.remove("c", "d") == "b")
        let left = Pane(["a", "b", "c", "d"], selected: "a")
        left.memory.select("c", in: left.id) // Close Tabs to the Left of c
        #expect(left.remove("a", "b") == "c")
        // The selected tab is the one acted on: it stays selected.
        let kept = Pane(["a", "b", "c", "d"], selected: "b")
        #expect(kept.remove("a", "c", "d") == "b")
    }

    @Test func theMembersOfACollapsedGroupAreSkippedWhileAShownTabSurvives() {
        // T [A B] C D, the group collapsed: C's close selects the next shown tab.
        let next = Pane(["t", "a", "b", "c", "d"], selected: "c")
        next.hidden = ["a", "b"]
        #expect(next.remove("c") == "d")
        // C is the last: the previous shown tab, past the collapsed group.
        let previous = Pane(["t", "a", "b", "c"], selected: "c")
        previous.hidden = ["a", "b"]
        #expect(previous.remove("c") == "t")
        // None shown: the nearest surviving tab (its group then expands).
        let none = Pane(["a", "b", "c"], selected: "c")
        none.hidden = ["a", "b"]
        #expect(none.remove("c") == "b")
        // A hidden opener is not selected: the next shown tab.
        let opener = Pane(["a", "b", "c"], selected: "a")
        opener.newTab("n")
        opener.hidden = ["a"]
        #expect(opener.remove("n") == "b")
    }

    /// Observed on Chrome 156 (decision 14:20Z): the next tab across a group's edge, the previous one only at
    /// the end of the strip. No group is read.
    @Test func aGroupsEdgeDoesNotChangeThePick() {
        #expect(Pane(["a", "b", "c", "d"], selected: "c").remove("c") == "d") // A [B C*] D
        #expect(Pane(["a", "b", "c", "d", "e"], selected: "d").remove("d") == "e") // A [B C D*] E
        #expect(Pane(["a", "b", "c", "d"], selected: "d").remove("d") == "c") // A B [C D*]
    }
}
