import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextBridge

/// Rapid switching 4 (Leo 2026-10-09): Home's tabs are never promoted out
/// into a new workspace or a new window by a drag.
struct TabPromoteGuardTests {
    static func context(staysPut: Bool, workspaceTabs: Int = 3, windowWorkspaces: Int = 2) -> TabDragContext {
        var context = TabDragContext(sourcePaneID: "pane-a", sourcePaneTabCount: workspaceTabs, sourceWorkspaceID: "home",
                                     sourceWorkspaceTabCount: workspaceTabs, draggedTabCount: 1,
                                     sourceWindowWorkspaceCount: windowWorkspaces)
        context.sourceStaysPut = staysPut
        return context
    }

    static func gap(_ context: TabDragContext) -> TabDragOutcome {
        TabDragResolver.outcome(for: TabDropProposal(kind: .newWorkspace(groupID: nil, index: 2), highlightFrame: .zero),
                                insideWindow: true, screenPoint: .zero, context: context)
    }

    static func outside(_ context: TabDragContext) -> TabDragOutcome {
        TabDragResolver.outcome(for: nil, insideWindow: false, screenPoint: CGPoint(x: 9, y: 9), context: context)
    }

    @Test func aHomeTabOnASidebarGapIsRefused() {
        let home = Self.context(staysPut: true)
        #expect(TabDragResolver.verdict(.newWorkspace(groupID: nil, index: 2), context: home) == .refuse(.staysPut))
        #expect(Self.gap(home) == .cancel)
        #expect(Self.gap(Self.context(staysPut: true, workspaceTabs: 1)) == .cancel, "Home's only tab does not move Home either")
    }

    @Test func aHomeTabReleasedOutsideEveryWindowSpringsBack() {
        #expect(Self.outside(Self.context(staysPut: true)) == .cancel)
        #expect(Self.outside(Self.context(staysPut: true, workspaceTabs: 1, windowWorkspaces: 1)) == .cancel)
        #expect(Self.outside(Self.context(staysPut: true, workspaceTabs: 1)) == .cancel)
    }

    @Test func anotherWorkspacesTabStillPromotes() {
        let other = Self.context(staysPut: false)
        #expect(TabDragResolver.verdict(.newWorkspace(groupID: nil, index: 2), context: other) == .accept)
        #expect(Self.gap(other) == .newWorkspace(groupID: nil, index: 2))
        #expect(Self.outside(other) == .tearOff(screenPoint: CGPoint(x: 9, y: 9)))
    }

    @Test func aHomeTabStillMovesInsideHome() {
        let home = Self.context(staysPut: true)
        #expect(TabDragResolver.verdict(.newSplit(paneID: "pane-b", edge: .left), context: home) == .accept)
    }
}
