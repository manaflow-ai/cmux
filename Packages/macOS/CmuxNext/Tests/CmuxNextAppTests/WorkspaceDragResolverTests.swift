import CoreGraphics
import Foundation
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// Where a sidebar workspace drag that left its sidebar ends.
struct WorkspaceDragResolverTests {
    let point = CGPoint(x: 40, y: 60)
    let slot = DropPosition(section: .machine(.local), index: 2)

    let split = TabDropKind.newSplit(paneID: "p", edge: .right)

    private func outcome(window: String?, hit: WorkspaceDropTarget? = nil, all: Bool = false, group: Bool = false,
                         layout: TabDropKind? = nil) -> WorkspaceDragOutcome {
        WorkspaceDragResolver.outcome(windowID: window, sidebarHit: hit, layoutHit: layout, sourceWindowID: "src", draggingAllOfSource: all,
                                      isGroup: group, screenPoint: point)
    }

    @Test func outsideEveryWindowTearsOffOrMovesTheWindow() {
        #expect(outcome(window: nil) == .newWindow(screenPoint: point))
        #expect(outcome(window: nil, all: true) == .moveWindow(screenPoint: point))
    }

    @Test func anotherWindowTakesTheDropAtTheSidebarTarget() {
        #expect(outcome(window: "b", hit: .position(slot)) == .window(id: "b", target: .position(slot)))
        #expect(outcome(window: "b", hit: .intoGroup(GroupID("g"))) == .window(id: "b", target: .intoGroup(GroupID("g"))))
        #expect(outcome(window: "b") == .window(id: "b", target: .window))
    }

    @Test func theSourceWindowOnlyAcceptsASidebarSlot() {
        #expect(outcome(window: "src") == .cancel)
        #expect(outcome(window: "src", hit: .window) == .cancel)
        #expect(outcome(window: "src", hit: .intoGroup(GroupID("g"))) == .cancel)
        #expect(outcome(window: "src", hit: .position(slot)) == .window(id: "src", target: .position(slot)))
    }

    @Test func groupsJoinAnotherWindowWhole() {
        #expect(outcome(window: "b", hit: .position(slot), group: true) == .window(id: "b", target: .window))
        #expect(outcome(window: "src", hit: .position(slot), group: true) == .cancel)
        #expect(outcome(window: nil, group: true) == .newWindow(screenPoint: point))
    }

    /// Leo 2026-10-06: a workspace dragged onto a pane of the shown
    /// workspace brings its tabs in, like a tab drag (center joins the
    /// pane, an edge makes a split). It did nothing: the source window
    /// refused everything but a sidebar slot.
    @Test func aPaneOfTheShownWorkspaceTakesTheWorkspacesTabs() {
        #expect(outcome(window: "src", layout: split) == .window(id: "src", target: .merge(split)))
        #expect(outcome(window: "b", layout: split) == .window(id: "b", target: .merge(split)))
        let join = TabDropKind.strip(stripID: UUID(), index: 3, groupID: nil)
        #expect(outcome(window: "src", layout: join) == .window(id: "src", target: .merge(join)))
    }

    @Test func theSidebarStillWinsOverThePanes() {
        #expect(outcome(window: "src", hit: .position(slot), layout: split) == .window(id: "src", target: .position(slot)))
    }

    @Test func aGroupNeverMergesIntoAPane() {
        #expect(outcome(window: "src", group: true, layout: split) == .cancel)
        #expect(outcome(window: "b", group: true, layout: split) == .window(id: "b", target: .window))
    }

    /// Lawrence 2026-10-05: any workspace merges into a pane, even one
    /// holding a single tab; only the fixed top rows (Home) never do.
    @Test func onlyHomeNeverMergesIntoAPane() {
        #expect(WorkspaceMerge.staysPut(kind: "home"))
        #expect(!WorkspaceMerge.staysPut(kind: nil))
        #expect(!WorkspaceMerge.staysPut(kind: "terminal"))
    }

    @Test func sidebarDropsMapToTargets() {
        #expect(WorkspaceDragResolver.target(for: .newWorkspace(section: .machine(.local), group: nil, index: 2)) == .position(slot))
        #expect(WorkspaceDragResolver.target(for: .intoGroup(GroupID("g"))) == .intoGroup(GroupID("g")))
        #expect(WorkspaceDragResolver.target(for: .intoWorkspace(WorkspaceID("w"))) == .window)
    }
}
