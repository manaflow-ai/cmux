import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// What a pinned member's row view draws (`sidebar.groupPinMark` = leading, the default): a member listed under
/// its group's header draws the pin before its name; a group of one member titled as the group draws no header,
/// so its one row stands for the group (`SidebarRow.standsForGroup`) and reads as the group, not a member pinned
/// inside it: no in-group pin there (review of #28708). The pin takes the title's color, not its group's (Aziz
/// 2026-11-06: "the pin color should just match the text color").
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarGroupPinRowViewTests {
    private func row(standsForGroup: Bool, tint: GroupTint? = nil) -> (WorkspaceRowView, NSWindow) {
        var ws = SidebarWorkspace(id: WorkspaceID("ws"), title: "deploy-checklist", lastActivity: Date())
        ws.isPinnedInGroup = true
        let content = SidebarLayoutOptions().rowContent(ws, machine: nil)
        var row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: GroupID("Release"), siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: true, isCollapsed: false, childCount: 0, groupColor: nil,
                             content: content)
        row.standsForGroup = standsForGroup
        let view = WorkspaceRowView(key: row.key)
        view.groupPinStyle = { _ in (.leading, tint) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 28), styleMask: .borderless,
                              backing: .buffered, defer: true)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
        view.configure(ws, row: row)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded() // updateLayer: the title's color, then the pin's
        return (view, window)
    }

    @Test func aPinnedMemberDrawsThePinBeforeItsName() {
        let (view, window) = row(standsForGroup: false)
        #expect(view.debugGroupPin == SidebarGroupPinMark.leading.rawValue)
        #expect(!view.groupPin.isHidden)
        #expect(view.groupPin.frame.maxX <= view.title.frame.minX, "the pin sits before the name")
        window.close()
    }

    @Test func aSoleMemberStandingForItsGroupDrawsNoPin() {
        let (view, window) = row(standsForGroup: true)
        #expect(view.debugGroupPin == nil)
        #expect(view.groupPin.isHidden)
        window.close()
    }

    @Test func thePinTakesTheTitlesColorNotItsGroups() {
        let (view, window) = row(standsForGroup: false, tint: .palette(.blue))
        view.updateLayer()
        #expect(view.groupPin.contentTintColor == view.title.textColor,
                "pin \(String(describing: view.groupPin.contentTintColor)), title \(view.title.textColor)")
        window.close()
    }
}

/// Tinted Rows (`sidebar.groupPinMark` shelf) wash a pinned member in the color its group's header draws. Under the
/// gradient palette that is the color at the group's place (`drawnTints`), not its stored token (review of #28708
/// after the gradient palette landed).
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarGroupPinPlacedTintTests {
    @Test func aPinnedMemberTakesItsGroupsPlacedColor() {
        let saved = DesignSettings.shared.sidebarSections
        defer { DesignSettings.shared.sidebarSections = saved }
        DesignSettings.shared.sidebarSections.groupPalette = .gradient
        DesignSettings.shared.sidebarSections.groupGradient = .aurora
        _ = NSApplication.shared
        let groups = GroupGradientPlacementTests.groups
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: groups.map { .group($0) })],
                                 activeWorkspaceID: nil)
        model.groupPinMark = .shelf
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sidebar
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        let ws = SidebarWorkspace(id: WorkspaceID("b-1"), title: "b")
        let row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: GroupID("b"), siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: true, isCollapsed: false, childCount: 0, groupColor: nil,
                             content: SidebarLayoutOptions().rowContent(ws, machine: nil))
        let placed = SidebarGroup.gradientTint(.aurora, at: 0.5)
        #expect(sidebar.list.drawnTints[GroupID("b")] == placed)
        let style = sidebar.list.groupPinStyle(row)
        #expect(style.0 == .shelf)
        #expect(style.1 == placed, "the wash follows the header's placed color, not the stored cyan")
    }
}
