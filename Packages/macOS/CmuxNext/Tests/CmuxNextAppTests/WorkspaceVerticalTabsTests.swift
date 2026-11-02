@testable import CmuxNextApp
import Foundation
import Testing

/// A workspace's own Turn On / Turn Off Vertical Tabs choice wins over Use Vertical Tabs for All Workspaces
/// (`tabs.verticalTabs`), survives a relaunch, and goes when the all-workspaces choice changes; Collapse Tabs
/// is one choice for every workspace.
@MainActor @Suite struct WorkspaceVerticalTabsTests {
    static func defaults() -> UserDefaults {
        let name = "WorkspaceVerticalTabsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aWorkspaceFollowsTheSettingUntilItChooses() {
        let store = WorkspaceVerticalTabs(defaults: Self.defaults())
        #expect(store.isVertical("ws_a", allWorkspaces: false) == false)
        #expect(store.isVertical("ws_a", allWorkspaces: true))
        store.set(true, for: "ws_a", allWorkspaces: false)
        #expect(store.isVertical("ws_a", allWorkspaces: false))
        #expect(store.isVertical("ws_b", allWorkspaces: false) == false, "one workspace's choice is its own")
        store.set(false, for: "ws_b", allWorkspaces: true)
        #expect(store.isVertical("ws_b", allWorkspaces: true) == false, "a workspace turns them off under the all-workspaces setting")
        #expect(store.isVertical(nil, allWorkspaces: true))
    }

    @Test func aChoiceEqualToTheSettingIsNoChoice() {
        let store = WorkspaceVerticalTabs(defaults: Self.defaults())
        store.set(true, for: "ws_a", allWorkspaces: false)
        store.set(false, for: "ws_a", allWorkspaces: false)
        #expect(store.choice(for: "ws_a") == nil)
        #expect(store.isVertical("ws_a", allWorkspaces: true), "with no choice left it follows the setting")
    }

    @Test func choicesAndCollapseSurviveARelaunch() {
        let defaults = Self.defaults()
        let store = WorkspaceVerticalTabs(defaults: defaults)
        store.set(true, for: "ws_a", allWorkspaces: false)
        store.setCollapsed(true)
        let relaunched = WorkspaceVerticalTabs(defaults: defaults)
        #expect(relaunched.choice(for: "ws_a") == true)
        #expect(relaunched.isCollapsed)
    }

    @Test func turningTheAllWorkspacesSettingClearsEveryChoice() {
        let defaults = Self.defaults()
        let store = WorkspaceVerticalTabs(defaults: defaults)
        store.set(true, for: "ws_a", allWorkspaces: false)
        store.set(false, for: "ws_b", allWorkspaces: true)
        store.clearChoices()
        #expect(store.choices.isEmpty)
        #expect(WorkspaceVerticalTabs(defaults: defaults).choices.isEmpty)
    }

    @Test func oldChoicesAreDroppedPastTheCap() {
        let store = WorkspaceVerticalTabs(defaults: Self.defaults())
        for index in 0...WorkspaceVerticalTabs.maximumWorkspaces { store.set(true, for: "ws_\(index)", allWorkspaces: false) }
        #expect(store.choices.count == WorkspaceVerticalTabs.maximumWorkspaces)
        #expect(store.choice(for: "ws_0") == nil, "the oldest choice goes first")
    }
}
