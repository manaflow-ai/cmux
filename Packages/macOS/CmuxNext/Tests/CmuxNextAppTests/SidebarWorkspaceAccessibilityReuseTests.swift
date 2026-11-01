import AppKit
@testable import CmuxNextSidebar
import Testing

@MainActor @Suite(.serialized)
struct SidebarWorkspaceAccessibilityReuseTests {
    @Test func retainedActionsCannotActOnAReusedWorkspaceRow() throws {
        _ = NSApplication.shared
        let row = WorkspaceRowView(key: .workspace(WorkspaceID("first")))
        row.treeFold = .collapsed
        var firstCalls = 0, secondCalls = 0
        row.onToggleTree = { firstCalls += 1 }
        row.onMore = { firstCalls += 1 }

        let oldActions = try #require(row.accessibilityCustomActions())
        #expect(oldActions.count == 2)
        row.prepareForReuse(key: .workspace(WorkspaceID("second")))
        row.treeFold = .collapsed
        row.onToggleTree = { secondCalls += 1 }
        row.onMore = { secondCalls += 1 }

        for action in oldActions { #expect(action.handler?() == false) }
        #expect(firstCalls == 0)
        #expect(secondCalls == 0)

        let currentActions = try #require(row.accessibilityCustomActions())
        for action in currentActions { #expect(action.handler?() == true) }
        #expect(secondCalls == 2)
    }

    @Test func retainedFoldActionCannotReverseAChangedFold() throws {
        _ = NSApplication.shared
        let row = WorkspaceRowView(key: .workspace(WorkspaceID("first")))
        row.treeFold = .collapsed
        var calls = 0
        row.onToggleTree = { calls += 1 }
        let expand = try #require(row.accessibilityCustomActions()?.first)

        row.treeFold = .expanded
        #expect(expand.handler?() == false)
        #expect(calls == 0)
    }

    @Test func retainedGroupActionsCannotActAfterReuse() throws {
        _ = NSApplication.shared
        let row = WorkspaceRowView(key: .workspace(WorkspaceID("first")))
        var calls = 0
        row.standingGroup = StandingGroupAccess(expanded: true, toggle: { calls += 1 }, edit: { calls += 1 },
                                                menu: { calls += 1 }, add: { calls += 1 })
        let oldActions = try #require(row.accessibilityCustomActions())
        #expect(oldActions.count == 4)

        row.prepareForReuse(key: .workspace(WorkspaceID("second")))
        for action in oldActions { #expect(action.handler?() == false) }
        #expect(calls == 0)
    }
}
