@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-18: the sidebar "keeps reordering sessions as they flip between in progress and not
/// in progress", "simultaneously noisy AND low signal". With `sidebar.sessionTree` on, rows hold
/// their places whatever their agents do: only the user moves a row (a drag, a create, a close).
/// Status shows in place, on the row's glyph.
@MainActor @Suite(.serialized) struct SidebarStableOrderTests {
    /// Fifty workspaces in a four-level spawn tree; each step changes one agent's state (waiting on
    /// you, failed, working, finished, an unread mark) and shows the rows again through the one
    /// writer (`SidebarRows`), as the store's live recompute does. The drawn order never changes.
    @Test func fiftySessionsChangingStateMoveNoRow() {
        #expect(Self.movesUnderFiftyStateChanges(window: nil) == 0)
    }

    /// The same run in a window that chose Move Sessions That Need You to Top: rows move, as before.
    @Test func aWindowThatChoseAttentionStillMovesRows() {
        #expect(Self.movesUnderFiftyStateChanges(window: .attention) > 0)
    }

    @Test func onlyTheSessionTreesOrderOrTheWindowsChoiceDecidesWhetherRowsMove() {
        var attention = AttentionSettings()
        var sections = SidebarSectionsPreferences.defaults
        #expect(sections.rowOrder == .stable)
        #expect(sections.movesRowsOnAttention(attention)) // without the tree, as before
        sections.sessionTree = true
        #expect(!sections.movesRowsOnAttention(attention))
        #expect(sections.movesRowsOnAttention(attention, window: .attention))
        sections.rowOrder = .attention
        #expect(sections.movesRowsOnAttention(attention))
        #expect(!sections.movesRowsOnAttention(attention, window: .stable)) // a window's choice wins
        attention.movesToTop = false
        #expect(!sections.movesRowsOnAttention(attention, window: .attention))
    }

    @Test func aWindowKeepsItsOwnOrderAcrossLaunches() {
        let defaults = UserDefaults(suiteName: "SidebarStableOrderTests.\(UUID().uuidString)") ?? .standard
        let memory = SidebarRowOrderMemory(defaults: defaults)
        let one = memory.restoring(SidebarModel(), window: "window-1")
        let two = memory.restoring(SidebarModel(), window: "window-2")
        #expect(one.rowOrder == nil)
        one.rowOrder = .attention
        #expect(memory.order(for: "window-1") == .attention)
        #expect(memory.order(for: "window-2") == nil)
        #expect(two.rowOrder == nil)
        #expect(memory.restoring(SidebarModel(), window: "window-1").rowOrder == .attention) // the next launch
        one.rowOrder = nil
        #expect(memory.order(for: "window-1") == nil)
    }

    /// The saved choices stay bounded: past ``SidebarRowOrderMemory/limit`` windows, the window
    /// that chose longest ago is forgotten (it follows the setting again), and a window choosing
    /// again moves to the newest.
    @Test func theSavedChoicesKeepOnlyTheNewestWindows() {
        let defaults = UserDefaults(suiteName: "SidebarStableOrderTests.\(UUID().uuidString)") ?? .standard
        let memory = SidebarRowOrderMemory(defaults: defaults)
        memory.save(.attention, for: "window-0")
        for n in 1..<SidebarRowOrderMemory.limit { memory.save(.stable, for: "window-\(n)") }
        memory.save(.attention, for: "window-0") // chose again: now the newest
        memory.save(.stable, for: "window-new")
        #expect(memory.order(for: "window-0") == .attention)
        #expect(memory.order(for: "window-1") == nil)
        #expect(memory.order(for: "window-new") == .stable)
        #expect(memory.count == SidebarRowOrderMemory.limit)
    }

    /// How many of 500 state changes moved a row, in a window that chose `window`.
    static func movesUnderFiftyStateChanges(window: SidebarRowOrder?) -> Int {
        let tree = SidebarDeepTreeTests.fiftySessionTree()
        var workspaces = tree.ids.map { SidebarWorkspace(id: $0, title: $0.rawValue) }
        func sections() -> [SidebarSection] {
            [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                            nodes: workspaces.map(SidebarNode.workspace))]
        }
        let saved = DesignSettings.shared.sidebarSections
        DesignSettings.shared.sidebarSections.sessionTree = true
        SidebarSessionTree.shared.state = SidebarSessionTreeState(parents: tree.parents)
        defer {
            DesignSettings.shared.sidebarSections = saved
            SidebarSessionTree.shared.state = nil
        }
        let model = SidebarModel(sections: sections())
        model.rowOrder = window
        let rows = SidebarRows(model: model)
        rows.show(sections())
        let home = model.visibleWorkspaceIDs

        let states: [StatusIndicatorState] = [.waiting, .error, .working, .success, .idle, .busy]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        var moves = 0
        for step in 0..<500 {
            let i = next(workspaces.count)
            workspaces[i].activity = states[next(states.count)]
            workspaces[i].agentWorking = next(2) == 0
            workspaces[i].unread = next(3) == 0 ? .dot : .none
            if step.isMultiple(of: 2) { rows.patch([workspaces[i]]) } else { rows.show(sections()) }
            if model.visibleWorkspaceIDs != home { moves += 1 }
        }
        return moves
    }
}
