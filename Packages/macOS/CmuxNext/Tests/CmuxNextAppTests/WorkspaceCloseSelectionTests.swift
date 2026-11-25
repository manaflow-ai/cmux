import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextBridge
@testable import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-11-10: closing a workspace "lowkey focuses the wrong workspace afterwards, we need to copy how
/// google chrome does it". The one close-selection rule (plans/cmux-next/close-focus.md, "One close-selection
/// rule"), driven through the state the window manager owns (`WindowCloseSelection`), the window's pick
/// (`WindowRegistry.repairedSelection`), the window state's feed, the create's gate and the sidebar model's own close.
struct WorkspaceCloseSelectionTests {
    private let window = "w"

    /// A person's New Workspace: `window` showed `old` and now shows `new`. `quick`: placed at the end or the top.
    private func make(_ new: String, from old: String, quick: Bool, in rule: WindowCloseSelection) {
        rule.expect(new, in: window, relation: quick ? .quick : .task)
        rule.shown(new, after: old, in: window, gesture: true)
    }

    /// The person selects `new` in the window (a click, a shortcut).
    private func go(_ new: String, from old: String, in rule: WindowCloseSelection) {
        rule.shown(new, after: old, in: window, gesture: true)
    }

    /// Closes `closed` while the window shows `shown`: the pick, then the workspace leaves the state.
    private func close(_ closed: String, shown: String, rows: [String], rule: WindowCloseSelection) -> String? {
        let pick = WindowRegistry.repairedSelection(current: shown, previous: rows, members: rows.filter { $0 != closed }, orders: [rows], rule: rule)
        rule.left(closed)
        return pick
    }

    // MARK: The default placement (after the current row): Chrome 156's observed middle-tab rows

    @Test func aNewWorkspaceAfterTheCurrentRowClosedAtOnceReturnsToTheOneHeCameFrom() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "n", "c", "d"]
        make("n", from: "b", quick: false, in: rule)
        #expect(close("n", shown: "n", rows: rows, rule: rule) == "b")
    }

    @Test func aVisitToItsOpenerAndBackStillReturnsToTheOpener() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "n", "c", "d"]
        make("n", from: "b", quick: false, in: rule)
        go("b", from: "n", in: rule)
        go("n", from: "b", in: rule)
        #expect(close("n", shown: "n", rows: rows, rule: rule) == "b")
    }

    @Test func aVisitToAnUnrelatedWorkspaceAndBackSelectsTheNextRow() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "n", "c", "d"]
        make("n", from: "b", quick: false, in: rule)
        go("d", from: "n", in: rule)
        go("n", from: "d", in: rule)
        #expect(rule.isEmpty)
        #expect(close("n", shown: "n", rows: rows, rule: rule) == "c")
    }

    // MARK: Placed at the end: the quick look-up

    @Test func aNewWorkspaceAtTheEndClosedAtOnceReturnsToTheOneHeCameFrom() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "c", "n"]
        make("n", from: "a", quick: true, in: rule)
        #expect(close("n", shown: "n", rows: rows, rule: rule) == "a")
    }

    @Test func anyVisitEndsTheQuickOpener() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "c", "n"]
        make("n", from: "a", quick: true, in: rule)
        go("a", from: "n", in: rule)
        go("n", from: "a", in: rule)
        #expect(rule.isEmpty)
        // The last row, with no opener: the row above it.
        #expect(close("n", shown: "n", rows: rows, rule: rule) == "c")
    }

    // MARK: No relation: by position

    @Test func closingAMiddleRowSelectsTheNextRow() {
        #expect(close("b", shown: "b", rows: ["a", "b", "c"], rule: WindowCloseSelection()) == "c")
    }

    @Test func closingTheLastRowSelectsThePreviousRow() {
        #expect(close("c", shown: "c", rows: ["a", "b", "c"], rule: WindowCloseSelection()) == "b")
    }

    @Test func aWorkspaceAScriptMadeHasNoOpener() {
        // Nothing expected it (the CLI, the socket, MCP, a restore, a move): the window showing it makes no relation.
        let rule = WindowCloseSelection(), rows = ["a", "n", "b", "c"]
        rule.shown("n", after: "a", in: window, gesture: false)
        #expect(rule.isEmpty)
        #expect(close("n", shown: "n", rows: rows, rule: rule) == "b")
    }

    @Test func closingAWorkspaceThatIsNotShownKeepsTheSelectionAndTheRelation() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "n", "c", "d"]
        make("n", from: "b", quick: false, in: rule)
        #expect(close("c", shown: "n", rows: rows, rule: rule) == "n")
        #expect(close("n", shown: "n", rows: ["a", "b", "n", "d"], rule: rule) == "b")
    }

    /// A move gets no opener: a tab moved to a new workspace (`TabMoves.toNewWorkspace`) is made by the daemon and
    /// its window shows it with no create reported, so closing it selects the next row, not the one it came from.
    @Test func aTabMovedToANewWorkspaceGetsNoOpener() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "moved", "c"]
        rule.shown("moved", after: "b", in: window, gesture: true)
        #expect(rule.isEmpty)
        #expect(close("moved", shown: "moved", rows: rows, rule: rule) == "c")
    }

    /// Only a person's own New Workspace reports a create (`WorkspaceSpawner.start`): a duplicate, a template, a
    /// session transfer and an import build a spawn with no New Tab page; the CLI, the socket, MCP and a run that
    /// may not change the view are not the person's foreground create.
    @Test func onlyAPersonsOwnNewWorkspaceReportsACreate() {
        let after = NewWorkspaceDefaultSlot(placement: .afterCurrent), end = NewWorkspaceDefaultSlot(placement: .bottom)
        let new = WorkspaceSpawn(newTabPage: true)
        let none = WindowCloseSelection.Relation.none
        #expect(new.closeRelation(setting: after) == .task)
        #expect(new.closeRelation(setting: end) == .quick)
        #expect(WorkspaceSpawn(cwd: "/tmp", name: "copy").closeRelation(setting: after) == none)
        ActionRunScope.carrying(ActionRunScope(origin: .cli, allowsViewChange: true)) { #expect(new.closeRelation(setting: after) == none) }
        ActionRunScope.carrying(ActionRunScope(origin: .user, allowsViewChange: false)) { #expect(new.closeRelation(setting: after) == none) }
    }

    /// The codes of `cmux_window_close_selection_relation` are not `CloseSelection.Kind`'s raw values (review of
    /// #40920): each case maps to Rust's constant by name. From Rust: the three answers. To Rust: a create with
    /// no relation holds nothing (the task and the quick relation each have their tests above).
    @Test func aCreatesRelationMapsToRustsConstantsByName() {
        #expect(WindowCloseSelection.relation(opensNewTabPage: true, personsAction: true, mayChangeView: true, afterCurrent: true) == .task)
        #expect(WindowCloseSelection.relation(opensNewTabPage: true, personsAction: true, mayChangeView: true, afterCurrent: false) == .quick)
        #expect(WindowCloseSelection.relation(opensNewTabPage: false, personsAction: true, mayChangeView: true, afterCurrent: true) == WindowCloseSelection.Relation.none)
        let rule = WindowCloseSelection()
        rule.expect("n", in: window, relation: .none)
        rule.shown("n", after: "b", in: window, gesture: true)
        #expect(rule.isEmpty)
    }

    @Test func aRelationDoesNotCrossWindows() {
        let rule = WindowCloseSelection()
        make("n", from: "b", quick: false, in: rule)
        // "n" moved to window "v"; the selection repair of "w" settles the state after its pick.
        rule.settle(window, owner: { $0 == "n" ? "v" : "w" }, exists: { _ in true }, claimed: { _ in false })
        #expect(rule.isEmpty)
        #expect(close("n", shown: "n", rows: ["x", "n", "y"], rule: rule) == "y")
    }

    /// A create that failed, or that its window listed and did not show (a background create), gets no opener
    /// when the window shows it later.
    @Test func aCreateTheWindowDidNotShowGetsNoOpener() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "n", "c"]
        rule.expect("n", in: window, relation: .task)
        // The window lists "n" and still shows "b": the repair after it settles the state.
        rule.settle(window, owner: { _ in "w" }, exists: { _ in true }, claimed: { _ in false })
        go("n", from: "b", in: rule)
        #expect(rule.isEmpty)
        #expect(close("n", shown: "n", rows: rows, rule: rule) == "c")
    }

    /// While its window waits for the create (not listed yet, still claimed), a repair keeps it.
    @Test func aRepairWhileTheCreateWaitsKeepsItsOpener() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "n", "c"]
        rule.expect("n", in: window, relation: .task)
        rule.settle(window, owner: { $0 == "n" ? nil : "w" }, exists: { _ in true }, claimed: { $0 == "n" })
        go("n", from: "b", in: rule)
        #expect(close("n", shown: "n", rows: rows, rule: rule) == "b")
    }

    // MARK: An opener or a closed workspace that no sidebar row lists (second review of #40649, M2 and S3)

    /// A pinned layout tile is a member no row lists. The person is on tile "p", makes "n" in the list and closes
    /// it: the window returns to "p". Before, only the rows of the order that lists "n" could be picked: "c".
    @Test func anOpenerNoRowListsIsStillSelected() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "n", "c"]
        make("n", from: "p", quick: false, in: rule)
        let pick = WindowRegistry.repairedSelection(current: "n", previous: rows + ["p"], members: ["a", "b", "c", "p"], orders: [rows, rows], rule: rule)
        #expect(pick == "p")
    }

    /// A tile that is not the opener is still never picked while a row is left, also with a relation held: a
    /// script selects "c" (no gesture, the relation of "n" stays) and "c", the last row, closes.
    @Test func aTileThatIsNotTheOpenerIsNotSelected() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "n", "c"]
        make("n", from: "b", quick: false, in: rule)
        rule.shown("c", after: "n", in: window, gesture: false)
        #expect(!rule.isEmpty)
        #expect(WindowRegistry.repairedSelection(current: "c", previous: rows + ["p"], members: ["a", "b", "n", "p"], orders: [rows, rows], rule: rule) == "n")
    }

    /// The new workspace closes before any sidebar row lists it (the rows come an observation later): the pick
    /// runs over the window's members, with the opener rank. Before, it was the neighbor by position: "c".
    @Test func aNewWorkspaceNoRowListsYetReturnsToItsOpener() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "c"]
        make("n", from: "b", quick: false, in: rule)
        #expect(WindowRegistry.repairedSelection(current: "n", previous: rows + ["n"], members: rows, orders: [rows, rows], rule: rule) == "b")
        #expect(WindowRegistry.repairedSelection(current: "n", previous: rows + ["n"], members: rows, rule: rule) == "b")
    }

    /// A person's close of several rows is the same pick as a close of one row (coordinator, FLAG 2; Chrome 156):
    /// the opener rank over the rows that survive. a b c d n*, "n" made from "b". Close Below on "c" (closes "d"
    /// and "n"): the opener "b". A close of "b" and "n": the opener closes with it and is no candidate, so the
    /// pick is by position, the row above the last. One row: the opener.
    @Test func aCloseOfSeveralRowsIsTheSamePickOverTheSurvivors() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "c", "d", "n"]
        make("n", from: "b", quick: false, in: rule)
        #expect(WindowRegistry.repairedSelection(current: "n", previous: rows, members: ["a", "b", "c"], orders: [rows], rule: rule) == "b")
        #expect(WindowRegistry.repairedSelection(current: "n", previous: rows, members: ["a", "c", "d"], orders: [rows], rule: rule) == "d")
        #expect(WindowRegistry.repairedSelection(current: "n", previous: rows, members: ["a", "b", "c", "d"], orders: [rows], rule: rule) == "b")
    }

    // MARK: The press of a close that can still be cancelled (`InstantClose`; review of #40920)

    /// The press hides the row and selects the pick at once. A quick relation of the hidden row lasts through the
    /// repair of the press only: the cancel shows the row again with its opener. A repair that is no press (a
    /// room change) ends it, as every selection that leaves the workspace does.
    @Test(arguments: [true, false]) func aQuickRelationLastsThroughThePressOfACloseOnly(pressed: Bool) {
        let rule = WindowCloseSelection(), rows = ["a", "b", "c", "n"], survivors = ["a", "b", "c"]
        make("n", from: "a", quick: true, in: rule)
        #expect(WindowRegistry.repairedSelection(current: "n", previous: rows, members: survivors, orders: [rows], rule: rule) == "a")
        rule.repair(shown: "n", pick: "a", gesture: false, pressed: pressed, members: survivors, preferred: []) { rule.shown("a", after: "n", in: window, gesture: true) }
        rule.repairing { rule.shown("n", after: "a", in: window, gesture: true) }
        #expect(close("n", shown: "n", rows: rows, rule: rule) == (pressed ? "a" : "c"))
    }

    /// A cancelled close of several rows whose pick was by position (the opener "b" closed with "n"): the rows are
    /// listed again and the window shows "n" again. That selection is the close's (`repairing`), and "n" keeps its
    /// opener. As a person's gesture it is a jump from "d" to an unrelated row, which ends the relation.
    @Test(arguments: [true, false]) func aCancelledCloseOfSeveralRowsKeepsTheOpener(asTheCloses: Bool) {
        let rule = WindowCloseSelection(), rows = ["a", "b", "c", "d", "n"], survivors = ["a", "c", "d"]
        make("n", from: "b", quick: false, in: rule)
        rule.repair(shown: "n", pick: "d", gesture: false, pressed: true, members: survivors, preferred: []) { rule.shown("d", after: "n", in: window, gesture: true) }
        if asTheCloses { rule.repairing { rule.shown("n", after: "d", in: window, gesture: true) } } else { rule.shown("n", after: "d", in: window, gesture: true) }
        #expect(close("n", shown: "n", rows: rows, rule: rule) == (asTheCloses ? "b" : "d"))
    }

    // MARK: Cost (Lawrence's session: 826 workspaces)

    /// With no relation held, a selection change, a close and a selection repair ask nothing about the window's
    /// members and read no rows; with one held, the repair asks the registry the two facts Rust wants (the owner,
    /// the waiting create) about that relation's two workspaces only. `settle` gets no row list at all (review of
    /// #40649, C and F), so it cannot walk the members.
    @Test(arguments: [3, 60, 826]) func aSwitchAndACloseNeverWalkTheMembers(count: Int) {
        final class Counter { var asked = 0, reads = 0 }
        let rows = (0..<count).map { "w\($0)" }, counter = Counter(), rule = WindowCloseSelection()
        func orders() -> [[String]] { counter.reads += 1; return [rows] }
        func settle() {
            rule.settle("w", owner: { _ in counter.asked += 1; return "w" },
                        exists: { _ in counter.asked += 1; return true }, claimed: { _ in counter.asked += 1; return false })
        }
        rule.shown(rows[1], after: rows[0], in: window, gesture: true)
        rule.left(rows[2])
        settle()
        #expect(WindowRegistry.repairedSelection(current: rows[1], previous: rows, members: rows.filter { $0 != rows[2] }, orders: orders(), rule: rule) == rows[1])
        #expect(counter.asked == 0)
        #expect(counter.reads == 0)
        make("n", from: rows[1], quick: false, in: rule)
        go(rows[1], from: "n", in: rule)
        settle()
        #expect(counter.asked == 4)
        #expect(!rule.isEmpty)
    }

    /// Rust asks about each workspace it holds; with more than the first call's 8 places the settle asks again
    /// with arrays that hold them all. 5 relations = 10 held workspaces: each is asked for its owner and its
    /// waiting create, and each relation is still there after the settle.
    @Test func aSettleAsksAboutEveryHeldWorkspace() {
        final class Counter { var asked = 0 }
        let rule = WindowCloseSelection(), counter = Counter()
        let rows = (0..<5).flatMap { ["o\($0)", "n\($0)"] }
        for index in 0..<5 {
            if index > 0 { rule.shown("o\(index)", after: "n\(index - 1)", in: window, gesture: false) }
            make("n\(index)", from: "o\(index)", quick: false, in: rule)
        }
        rule.settle(window, owner: { _ in counter.asked += 1; return window }, exists: { _ in true }, claimed: { _ in counter.asked += 1; return false })
        #expect(counter.asked == 20)
        // With no opener the pick is the next row (the opener of the next pair); only for the last row is it the row above.
        for index in 0..<5 {
            #expect(WindowRegistry.repairedSelection(current: "n\(index)", previous: rows, members: rows.filter { $0 != "n\(index)" }, orders: [rows], rule: rule) == "o\(index)")
        }
    }

    // MARK: The feed (WindowState through `WindowCloseSelection.watch`) and the sidebar model's own close

    @Test func aPersonsNewWorkspaceGetsItsOpenerFromTheWindowsSelection() {
        let services = MachineIconTests.services(), windows = services.windows
        _ = windows.registry.apply { $0.openWindow(id: window, workspaceIDs: ["a", "b", "n", "c"]) }
        let state = windows.state(for: window), rule = windows.registry.closeSelection
        state.showWorkspace("b")
        rule.expect("n", in: window, relation: .task)
        #expect(rule.isEmpty)
        state.showWorkspace("n")
        #expect(!rule.isEmpty)
        #expect(close("n", shown: "n", rows: ["a", "b", "n", "c"], rule: rule) == "b")
    }

    /// A selection a script, the CLI or MCP makes is not the person's gesture: it does not end the relation.
    @Test func aScriptsSelectionIsNoGesture() {
        let services = MachineIconTests.services(), windows = services.windows
        _ = windows.registry.apply { $0.openWindow(id: window, workspaceIDs: ["a", "b", "n", "c", "d"]) }
        let state = windows.state(for: window), rule = windows.registry.closeSelection
        state.showWorkspace("b")
        rule.expect("n", in: window, relation: .task)
        state.showWorkspace("n")
        ActionRunScope.carrying(ActionRunScope(origin: .cli, allowsViewChange: true)) {
            state.showWorkspace("d")
            state.showWorkspace("n")
        }
        #expect(close("n", shown: "n", rows: ["a", "b", "n", "c", "d"], rule: rule) == "b")
    }

    /// The window's selection repair (every close entry point) picks and selects at the press; the relation of
    /// the closed workspace ends when the registry no longer lists it (the close is committed), not before
    /// (review of #40649, F: a cancelled or refused close shows the row again with its opener).
    @Test func theRepairSelectsTheOpenerAndTheCommittedCloseEndsTheRelation() {
        let store = WindowRegistryStore(), rows = ["a", "b", "n", "c"]
        _ = store.apply { $0.openWindow(id: window, workspaceIDs: rows) }
        make("n", from: "b", quick: false, in: store.closeSelection)
        var selected: String??
        store.repairSelection(of: window, shown: "n", previous: rows, members: ["a", "b", "c"], gesture: false, orders: [rows]) { selected = $0 }
        #expect(selected == .some("b"))
        #expect(!store.closeSelection.isEmpty)
        _ = store.apply { $0.reconcile(live: ["a", "b", "c"], dead: ["n"], fallbackWindow: window) }
        store.repairSelection(of: window, shown: "b", previous: rows, members: ["a", "b", "c"], gesture: false, orders: [rows]) { selected = $0 }
        #expect(store.closeSelection.isEmpty)
    }

    /// Review of #40649, A: a workspace in `preferred` is the person's only when the caller says so. A daemon
    /// delta's caller says "no gesture", so the selection it causes keeps the relations, whatever the run's scope
    /// says (none surrounds a delta, and no scope reads as the person's).
    @Test(arguments: [false, true]) func onlyTheCallerMakesAPreferredSelectionAGesture(gesture: Bool) {
        let store = WindowRegistryStore(), rows = ["a", "b", "n", "c", "x"]
        _ = store.apply { $0.openWindow(id: window, workspaceIDs: rows) }
        make("n", from: "b", quick: false, in: store.closeSelection)
        store.repairSelection(of: window, shown: "n", previous: ["a", "b", "n", "c"], members: rows, preferred: ["x"], gesture: gesture, orders: [rows]) {
            store.closeSelection.shown($0, after: "n", in: window, gesture: true)
        }
        #expect(store.closeSelection.isEmpty == gesture)
    }

    /// Review of #40649, E: the launch window takes a saved window's identity; its creates and relations follow.
    @Test func aRenamedWindowKeepsItsCreatesAndRelations() {
        let rule = WindowCloseSelection(), rows = ["a", "b", "n", "m", "c"]
        make("n", from: "b", quick: false, in: rule)
        rule.expect("m", in: window, relation: .task)
        rule.renamed(window: window, to: "w2")
        rule.settle("w2", owner: { $0 == "m" ? nil : "w2" }, exists: { $0 == "w2" }, claimed: { $0 == "m" })
        #expect(!rule.isEmpty)
        rule.shown("m", after: "n", in: "w2", gesture: true)
        #expect(close("m", shown: "m", rows: rows, rule: rule) == "n")
        #expect(close("n", shown: "n", rows: ["a", "b", "n", "c"], rule: rule) == "b")
    }

    /// The sidebar's own close (`SidebarModel.apply(.close)`) and the window's repair give one answer for one close.
    @Test func theSidebarsCloseAndTheWindowsRepairAgree() {
        let rows = ["a", "b", "n", "c"], ids = rows.map { CmuxNextSidebar.WorkspaceID($0) }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: ids.map { .workspace(SidebarWorkspace(id: $0, title: $0.rawValue)) })],
                                 activeWorkspaceID: ids[2])
        let rule = WindowCloseSelection()
        model.drawnWorkspaceOrder = { ids }
        model.closeSuccessor.pick = { rule.pick(shown: $0, previous: $1, members: $2, orders: $3) }
        make("n", from: "b", quick: false, in: rule)
        let repaired = WindowRegistry.repairedSelection(current: "n", previous: rows, members: ["a", "b", "c"], orders: [rows], rule: rule)
        model.apply(.close([ids[2]]))
        #expect(repaired == "b")
        #expect(model.activeWorkspaceID?.rawValue == repaired)
    }
}
