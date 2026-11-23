import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing

/// The window dock (user 2026-11-05): a dock of the window frame any pane moves into, with the Home Chief pane's
/// no-tab-bar mode toggled per dock, and the Chief window dock on Cmd-I. These pin the value rules the window
/// controller drives (`WindowDocks`), the saved record and the catalog's keys; `WindowDockWindowTests` drives a
/// real window.
@Suite
struct WindowDockModelTests {
    @Test func theNoTabBarModeIsPerDockAndKeepsASecondTabReachable() {
        var docks = WindowDocks()
        docks.dock("ws-chief", at: .left)
        docks.dock("ws-logs", at: .bottom)
        #expect(!docks.hidesTabBar(of: "ws-chief", shownTabs: 1), "off by default, as before")
        #expect(docks.toggleTabBar("ws-chief") == true)
        #expect(docks.hidesTabBar(of: "ws-chief", shownTabs: 1), "one tab: no tab bar, as the Home Chief pane")
        #expect(!docks.hidesTabBar(of: "ws-chief", shownTabs: 2), "a tab dragged in brings the bar back")
        #expect(!docks.hidesTabBar(of: "ws-logs", shownTabs: 1), "per dock: the other dock keeps its bar")
        #expect(!docks.hidesTabBar(of: "ws-stage", shownTabs: 1), "a workspace in no dock keeps its bar")
        #expect(docks.toggleTabBar("ws-chief") == false)
        #expect(docks.toggleTabBar("ws-none") == nil)
    }

    @Test func movingADockKeepsItsModeExtentAndTabBarAndShowsIt() {
        var docks = WindowDocks()
        docks.dock("ws-chief", at: .left, mode: .overlay, extentPermille: 420)
        docks.toggleTabBar("ws-chief")
        _ = docks.toggle(.left)
        docks.dock("ws-other", at: .right)
        let displaced = docks.move("ws-chief", to: .right)
        #expect(displaced == "ws-other", "W1: the dock that held the edge goes back to the sidebar")
        let moved = docks.dock(at: .right)
        #expect(moved?.workspace == "ws-chief")
        #expect(moved?.mode == .overlay && moved?.extentPermille == 420 && moved?.hidesTabBar == true)
        #expect(moved?.hidden == false, "a moved dock shows")
        #expect(docks.dock(at: .left) == nil)
        #expect(docks.move("ws-none", to: .top) == nil)
    }

    @Test func theActionsTargetTheFocusedDockElseTheFirstShown() {
        var docks = WindowDocks()
        #expect(docks.target(focused: "ws-a") == nil)
        docks.dock("ws-l", at: .left)
        docks.dock("ws-b", at: .bottom)
        #expect(docks.target(focused: "ws-b")?.workspace == "ws-b", "the dock with the focus")
        #expect(docks.target(focused: "ws-stage")?.workspace == "ws-l", "else the first shown")
        _ = docks.toggle(.left)
        #expect(docks.target(focused: "ws-stage")?.workspace == "ws-b")
        _ = docks.toggle(.bottom)
        #expect(docks.target(focused: "ws-stage")?.workspace == "ws-l", "else the first hidden")
    }

    @Test func theTabBarModeRoundTripsThroughTheWindowRecordAndOlderRecordsReadOff() throws {
        var docks = WindowDocks()
        docks.dock("ws-chief", at: .left)
        docks.toggleTabBar("ws-chief")
        docks.dock("ws-logs", at: .bottom)
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: "ws-c"))
        docks.store(into: &record, stage: "ws-c")
        let data = try JSONEncoder().encode(record)
        let restored = WindowDocks(record: try JSONDecoder().decode(WindowRecord.self, from: data))
        #expect(restored.dock(at: .left)?.hidesTabBar == true)
        #expect(restored.dock(at: .bottom)?.hidesTabBar == false)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.components(separatedBy: "hide_tab_bar").count == 2, "written only for the dock that has it")
        let older = try JSONDecoder().decode(WindowDockRecord.self, from: Data(#"{"edge":"left","workspace_key":"ws-a"}"#.utf8))
        #expect(!older.hidesTabBar)
    }

    /// Cmd-I is Show/Hide Chief (user 2026-11-06: "Cmd+I must also hide the docked Chief"); New Agent Chat keeps its
    /// leader chord and the palette, so no two actions share Cmd-I.
    @Test func cmdIShowsAndHidesTheChief() throws {
        let registry = ActionRegistry.standard()
        let cmdI = Shortcut("i", modifiers: [.command])
        let open = try #require(registry.descriptors.first { $0.id == "home.openChiefDock" })
        #expect(open.defaultShortcut == cmdI)
        #expect(open.surfaces.contains(.palette) && open.surfaces.contains(.keyboard), "rebindable and in Cmd-Shift-P")
        #expect(registry.descriptors.filter { $0.defaultShortcut == cmdI }.map(\.id) == ["home.openChiefDock"])
        #expect(registry.descriptors.first { $0.id == "palette.newAgentChat" }?.defaultShortcut == nil)
        for id in ["window.movePaneToDock", "window.toggleDock", "window.toggleDockTabBar", "window.focusDock",
                   "window.dockEdgeLeft", "window.dockEdgeRight", "window.dockEdgeTop", "window.dockEdgeBottom"] as [ActionID] {
            let descriptor = try #require(registry.descriptors.first { $0.id == id }, "\(id) is not in the catalog")
            #expect(descriptor.surfaces.contains(.palette), "\(id) is not in Cmd-Shift-P")
        }
    }
}
