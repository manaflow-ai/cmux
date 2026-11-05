import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// What a pinned member's row view draws (`sidebar.groupPinMark` = leading, the default): a member listed under
/// its group's header draws the pin before its name; a group of one member titled as the group draws no header,
/// so its one row stands for the group (`SidebarRow.standsForGroup`) and reads as the group, not a member pinned
/// inside it: no in-group pin there (review of #28708).
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarGroupPinRowViewTests {
    private func row(standsForGroup: Bool) -> (WorkspaceRowView, NSWindow) {
        var ws = SidebarWorkspace(id: WorkspaceID("ws"), title: "deploy-checklist", lastActivity: Date())
        ws.isPinnedInGroup = true
        let content = SidebarLayoutOptions().rowContent(ws, machine: nil)
        var row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: GroupID("Release"), siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: true, isCollapsed: false, childCount: 0, groupColor: nil,
                             content: content)
        row.standsForGroup = standsForGroup
        let view = WorkspaceRowView(key: row.key)
        view.groupPinStyle = { _ in (.leading, nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 28), styleMask: .borderless,
                              backing: .buffered, defer: true)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
        view.configure(ws, row: row)
        view.layoutSubtreeIfNeeded()
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
}
