import AppKit
@testable import CmuxNextSidebar
import Testing

@MainActor @Suite(.serialized)
struct SidebarWorkspaceAccessibilityReuseTests {
    @Test func retainedActionsCannotActOnAReusedWorkspaceRow() throws {
        _ = NSApplication.shared
        let row = WorkspaceRowView(key: .workspace(WorkspaceID("first")))
        row.disclosure = .collapsed
        row.treeFold = .collapsed
        var firstCalls = 0, secondCalls = 0
        row.onToggleTabs = { firstCalls += 1 }
        row.onToggleTree = { firstCalls += 1 }
        row.onMore = { firstCalls += 1 }

        let oldActions = try #require(row.accessibilityCustomActions())
        #expect(oldActions.count == 3)
        row.prepareForReuse(key: .workspace(WorkspaceID("second")))
        row.disclosure = .collapsed
        row.treeFold = .collapsed
        row.onToggleTabs = { secondCalls += 1 }
        row.onToggleTree = { secondCalls += 1 }
        row.onMore = { secondCalls += 1 }

        for action in oldActions { #expect(action.handler?() == false) }
        #expect(firstCalls == 0)
        #expect(secondCalls == 0)

        let currentActions = try #require(row.accessibilityCustomActions())
        for action in currentActions { #expect(action.handler?() == true) }
        #expect(secondCalls == 3)
    }

    @Test func retainedFoldActionCannotReverseAChangedFold() throws {
        _ = NSApplication.shared
        let row = WorkspaceRowView(key: .workspace(WorkspaceID("first")))
        row.disclosure = .collapsed
        var calls = 0
        row.onToggleTabs = { calls += 1 }
        let showTabs = try #require(row.accessibilityCustomActions()?.first)

        row.disclosure = .expanded
        #expect(showTabs.handler?() == false)
        #expect(calls == 0)
    }
}
