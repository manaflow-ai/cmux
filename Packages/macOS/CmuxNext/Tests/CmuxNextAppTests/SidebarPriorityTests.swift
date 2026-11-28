import CmuxNextSidebar
import Foundation
import Testing

struct SidebarPriorityTests {
    @Test func actionableRowsLeadAndFinishedRowsFollowLiveWork() {
        let now = Date(timeIntervalSince1970: 10_000)
        let waiting = SidebarWorkspace(id: .init("waiting"), title: "waiting", lastActivity: now.addingTimeInterval(-100), activity: .waiting)
        let failed = SidebarWorkspace(id: .init("failed"), title: "failed", lastActivity: now.addingTimeInterval(-200), activity: .error)
        let working = SidebarWorkspace(id: .init("working"), title: "working", lastActivity: now.addingTimeInterval(-300), activity: .working)
        let finished = SidebarWorkspace(id: .init("finished"), title: "finished", lastActivity: now.addingTimeInterval(-400), activity: .success)

        let result = SidebarPriority().items([finished, working, failed, waiting])
        #expect(result.map { $0.id.rawValue } == ["waiting", "failed", "working", "finished"])
    }

    @Test func sameBucketRetainsManualOrder() {
        let now = Date(timeIntervalSince1970: 10_000)
        let old = SidebarWorkspace(id: .init("old"), title: "old", lastActivity: now.addingTimeInterval(-10), activity: .working)
        let recent = SidebarWorkspace(id: .init("recent"), title: "recent", lastActivity: now, activity: .working)
        let tieA = SidebarWorkspace(id: .init("a"), title: "a", activity: .idle)
        let tieB = SidebarWorkspace(id: .init("b"), title: "b", activity: .idle)

        let result = SidebarPriority().items([old, tieB, tieA, recent])
        #expect(result.map { $0.id.rawValue } == ["old", "recent", "b", "a"])
    }

    @Test func placeholdersAreExcludedAndLimitIsClamped() {
        let placeholder = SidebarWorkspace(id: .init("placeholder"), title: "placeholder", rowState: .placeholder)
        let live = SidebarWorkspace(id: .init("live"), title: "live", activity: .working)

        #expect(SidebarPriority().items([placeholder, live], limit: 1).map { $0.id.rawValue } == ["live"])
        #expect(SidebarPriority().items([live], limit: -1).isEmpty)
    }

    @Test func unreadRowsAreActionableEvenWithoutAnActivityState() {
        let idle = SidebarWorkspace(id: .init("idle"), title: "idle")
        let unread = SidebarWorkspace(id: .init("unread"), title: "unread", unread: .dot)

        #expect(SidebarPriority().items([idle, unread]).map { $0.id.rawValue } == ["unread", "idle"])
    }

    @Test func reordersNodesWithoutMovingPinnedRows() {
        let waiting = SidebarWorkspace(id: .init("waiting"), title: "waiting", activity: .waiting)
        let idle = SidebarWorkspace(id: .init("idle"), title: "idle")
        let group = SidebarGroup(id: .init("group"), name: "Group", workspaces: [idle, waiting])
        let pinned = SidebarSection(kind: .pinned, nodes: [.workspace(idle)])
        let machine = SidebarSection(kind: .machine(.init(id: .local, name: "This Mac", kind: .local)), nodes: [.workspace(idle), .group(group)])

        let sections = SidebarPriority().reordered([pinned, machine])
        #expect(sections[0].nodes == [.workspace(idle)])
        #expect(sections[1].nodes.map(\.id) == [.group(.init("group")), .workspace(.init("idle"))])
        guard case let .group(reorderedGroup) = sections[1].nodes[0] else { return #expect(Bool(false)) }
        #expect(reorderedGroup.workspaces.map(\.id) == [.init("waiting"), .init("idle")])
    }
}
