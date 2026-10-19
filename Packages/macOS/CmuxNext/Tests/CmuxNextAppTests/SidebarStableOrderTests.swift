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
        let rows = SidebarRows(model: model)
        rows.show(sections())
        let home = model.visibleWorkspaceIDs
        #expect(home.count == 50)

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
        #expect(moves == 0, "rows moved on \(moves) of 500 state changes")
    }
}
