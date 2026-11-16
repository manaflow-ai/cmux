import CmuxNextBridge
import CmuxNextDaemon
import Testing

/// A tab that this window makes shows first as a stand-in, and the daemon's tab takes its place later. The two are
/// one item to the close-selection rule: the opener of the stand-in is the opener of its tab, and a pane that selects
/// the stand-in selects its tab. Which tab a stand-in became is the store's record of the creation
/// (``StandInFate``), not a count of the tabs that left and arrived: with a held New Tab key, two or more stand-ins
/// get their tabs in one apply of the pane.
///
/// Driven through the window's selection memory, as a pane's apply drives it. A stand-in's id has the prefix of
/// `ProvisionalTab`.
@MainActor
struct TabStandInOpenerTests {
    /// One pane's strip: its tabs in strip order, and what the store's record says of each stand-in.
    @MainActor
    private final class Pane {
        let memory = TabSelectionMemory()
        let id = "pane"
        var tabs: [String]
        /// The fate of each stand-in that the pane no longer lists; none: ended.
        var fates: [String: StandInFate] = [:]

        init(_ tabs: [String], selected: String) {
            self.tabs = tabs
            memory.select(selected, in: id)
            sync()
        }

        var selected: String? { memory.selection(in: id) }

        /// The pane's apply: the tab it shows for its tabs as they are now.
        @discardableResult
        func sync() -> String? {
            memory.resolve(pane: id, tabs: tabs, defaultIndex: 0, standIn: { self.fates[$0] ?? .ended })
        }

        /// A person's New Tab key: stand-in `tab` goes right after the selected tab and is selected at once.
        func newTab(_ tab: String) {
            guard let current = selected, let index = tabs.firstIndex(of: current) else { return }
            memory.closeRule.expect(in: id, opener: current, listed: tabs, quick: false)
            tabs.insert(tab, at: index + 1)
            memory.selectMade(tab, in: id, inPlaceOf: nil, tabs: tabs, standIn: { self.fates[$0] ?? .ended })
            sync()
        }

        /// The daemon's tabs take their stand-ins' places, all in ONE apply; returns the tab the pane shows then.
        @discardableResult
        func answer(_ pairs: KeyValuePairs<String, String>) -> String? {
            for (standIn, tab) in pairs {
                if let index = tabs.firstIndex(of: standIn) { tabs[index] = tab }
                fates[standIn] = .became(tab)
            }
            return sync()
        }

        /// `tab` leaves the pane; returns the tab the pane shows then.
        @discardableResult
        func remove(_ tab: String) -> String? {
            tabs.removeAll { $0 == tab }
            return sync()
        }
    }

    private static let first = ProvisionalTab.idPrefix + "1", second = ProvisionalTab.idPrefix + "2"

    /// `a b c` with `b` selected, then two New Tab keys: `a b first second c`, `second` selected. `first` was opened
    /// from `b`, `second` from `first`.
    private static func heldNewTab() -> Pane {
        let pane = Pane(["a", "b", "c"], selected: "b")
        pane.newTab(first)
        pane.newTab(second)
        return pane
    }

    @Test func twoStandInsAnsweredInOneApplyKeepTheirOpeners() {
        let pane = Self.heldNewTab()
        // The reply of the newer creation came first: the pane selects its tab as it arrives.
        pane.tabs = ["a", "b", "t1", "t2", "c"]
        pane.fates = [Self.first: .became("t1"), Self.second: .became("t2")]
        pane.memory.selectMade("t2", in: pane.id, inPlaceOf: nil, tabs: pane.tabs, standIn: { pane.fates[$0] ?? .ended })
        #expect(pane.sync() == "t2")
        // `t2` opened no tab and no other tab has its opener: its opener `t1` is next, then `t1`'s opener `b`.
        #expect(pane.remove("t2") == "t1")
        #expect(pane.remove("t1") == "b")
    }

    @Test func theSelectedStandInAnsweredTogetherWithAnotherKeepsTheSelection() {
        let pane = Self.heldNewTab()
        // No reply came yet: the two events are one apply, and no Close Tab key was pressed.
        #expect(pane.answer([Self.first: "t1", Self.second: "t2"]) == "t2")
        #expect(pane.selected == "t2")
        #expect(pane.remove("t2") == "t1")
    }

    @Test func aSelectedStandInAnsweredAloneKeepsTheSelection() {
        let pane = Pane(["a", "b", "c"], selected: "b")
        pane.newTab(Self.first)
        #expect(pane.answer([Self.first: "t1"]) == "t1")
        #expect(pane.remove("t1") == "b")
    }

    /// A second New Tab key between the store's record of the first creation's tab and the pane's apply of it. The
    /// pane still selects the first stand-in, the records have its tab `t1`, and the new stand-in goes right after
    /// `t1`. The selected stand-in became `t1`, not the tab that the pane selects now: `t1` keeps the opener of its
    /// stand-in, and the opener of the second stand-in is `t1`.
    @Test func aNewTabBeforeThePaneAppliesTheReplyOfTheSelectedStandInKeepsBothOpeners() {
        let pane = Pane(["a", "b", "c"], selected: "b")
        pane.newTab(Self.first)
        pane.fates[Self.first] = .became("t1")
        // The New Tab key reads the records: the pane's current tab is `t1`.
        pane.memory.closeRule.expect(in: pane.id, opener: "t1", listed: ["a", "b", "t1", "c"], quick: false)
        pane.tabs = ["a", "b", "t1", Self.second, "c"]
        pane.memory.selectMade(Self.second, in: pane.id, inPlaceOf: nil, tabs: pane.tabs, standIn: { pane.fates[$0] ?? .ended })
        #expect(pane.sync() == Self.second)
        #expect(pane.remove(Self.second) == "t1")
        #expect(pane.remove("t1") == "b")
    }

    /// The stand-in leaves the pane's list before its tab is listed: its creation is not answered yet (`underway`),
    /// or its tab is in the records and the strip does not list it yet (`became`).
    @Test(arguments: [StandInFate.underway, .became("t1")])
    func aStandInThatWaitsForItsTabKeepsItsOpener(waiting: StandInFate) {
        let pane = Self.heldNewTab()
        pane.fates[Self.first] = waiting
        #expect(pane.remove(Self.first) == Self.second)
        // Its tab is listed now, in its place.
        pane.tabs = ["a", "b", "t1", Self.second, "c"]
        pane.fates[Self.first] = .became("t1")
        #expect(pane.sync() == Self.second)
        #expect(pane.remove(Self.second) == "t1")
        #expect(pane.remove("t1") == "b")
    }

    /// The wait has an end: a stand-in whose creation fails or is refused after a wait ends its relations.
    @Test func aStandInWhoseCreationFailsAfterAWaitEndsItsRelations() {
        let pane = Self.heldNewTab()
        pane.fates[Self.first] = .underway
        #expect(pane.remove(Self.first) == Self.second)
        pane.fates[Self.first] = .ended
        pane.sync()
        // `second` took the opener of `first`, as the tabs of a closed tab do.
        #expect(pane.remove(Self.second) == "b")
        #expect(pane.memory.closeRule.isEmpty)
    }

    /// Close Tab on the selected stand-in before its creation has a reply (the close cancels the creation), and a
    /// creation that fails or is refused: the store's record says `ended` for each. The stand-in is a closed tab:
    /// the tab it came from is selected in that same apply, and no tab takes its place. The state keeps nothing of
    /// it: when the tab it came from closes too, no relation is left.
    @Test func aStandInClosedBeforeItsReplyIsAClosedTab() {
        let pane = Self.heldNewTab()
        #expect(pane.remove(Self.second) == Self.first)
        #expect(pane.selected == Self.first)
        #expect(pane.remove(Self.first) == "b")
        #expect(pane.memory.closeRule.isEmpty)
    }

    /// The tabs of both stand-ins are in the records, and the strip lists neither yet: it holds back a pane's new
    /// tabs while another open of the pane has no answer. No tab closed, so the selection stays on the stand-in, and
    /// its tab is selected when the strip lists it.
    @Test func aSelectedStandInWhoseTabIsNotListedYetKeepsTheSelection() {
        let pane = Self.heldNewTab()
        pane.fates = [Self.first: .became("t1"), Self.second: .became("t2")]
        pane.tabs = ["a", "b", "c"]
        #expect(pane.sync() == Self.second)
        #expect(pane.selected == Self.second)
        // The strip lists both tabs now, each in its stand-in's place.
        pane.tabs = ["a", "b", "t1", "t2", "c"]
        #expect(pane.sync() == "t2")
        #expect(pane.remove("t2") == "t1")
        #expect(pane.remove("t1") == "b")
    }

    /// That wait has an end too: the tab leaves the records before the strip lists it (closed, or moved away). The
    /// stand-in is a closed tab then, and the pick is a close's pick from the place that the stand-in had.
    @Test func aSelectedStandInWhoseTabLeavesBeforeItIsListedIsAClosedTab() {
        let pane = Pane(["a", "b", "c"], selected: "b")
        pane.newTab(Self.first)
        pane.fates[Self.first] = .became("t1")
        #expect(pane.remove(Self.first) == Self.first)
        pane.fates[Self.first] = .ended
        #expect(pane.sync() == "b")
        #expect(pane.memory.closeRule.isEmpty)
    }
}
