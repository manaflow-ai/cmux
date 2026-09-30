import CoreGraphics
@testable import CmuxNextApp
import CmuxNextSidebar
import Testing

/// Where a sidebar workspace drag that left its sidebar ends.
struct WorkspaceDragResolverTests {
    let point = CGPoint(x: 40, y: 60)
    let slot = DropPosition(section: .machine(.local), index: 2)

    private func outcome(window: String?, hit: WorkspaceDropTarget? = nil, all: Bool = false, group: Bool = false) -> WorkspaceDragOutcome {
        WorkspaceDragResolver.outcome(windowID: window, sidebarHit: hit, sourceWindowID: "src", draggingAllOfSource: all,
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

    @Test func sidebarDropsMapToTargets() {
        #expect(WorkspaceDragResolver.target(for: .newWorkspace(section: .machine(.local), group: nil, index: 2)) == .position(slot))
        #expect(WorkspaceDragResolver.target(for: .intoGroup(GroupID("g"))) == .intoGroup(GroupID("g")))
        #expect(WorkspaceDragResolver.target(for: .intoWorkspace(WorkspaceID("w"))) == .window)
    }
}
