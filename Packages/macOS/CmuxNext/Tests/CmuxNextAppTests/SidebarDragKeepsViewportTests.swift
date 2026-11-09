import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-06: "Suppose I drag a workspace from the bottom to the top ... I'm scrolled to the very bottom ... the
/// focusing gets weird? it jumps me up or to the bottom". A press switches to its row on mouse-down; once the press
/// becomes a drag, the list puts back the workspace shown before the press. That put-back is no focus change, yet it
/// revealed that workspace: with it far above a list scrolled to its end, the list jumped to the top as the row lifted.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarDragKeepsViewportTests {
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    @Test func liftingARowNearTheBottomKeepsTheScrolledListWhereItIs() throws {
        _ = NSApplication.shared
        let all = Array(1...40)
        let start = Self.sections(all)
        let ids = try #require(start.first?.workspaces.map(\.id))
        try #require(ids.count == all.count)
        // The shown workspace is the first row, far above the end of the list.
        let model = SidebarModel(sections: start, activeWorkspaceID: ids[0])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 320)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        defer { window.close() }
        sidebar.layoutSubtreeIfNeeded()
        let list = sidebar.list
        list.reload(animated: false)
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let clip = try #require(list.enclosingScrollView?.contentView)

        // Scrolled to the very bottom.
        let end = max(0, list.displayed.totalHeight - clip.bounds.height)
        list.scrollClip(to: end, animated: false)
        try #require(end > 100 && abs(clip.bounds.minY - end) < 0.5, "the sidebar did not scroll to its end \(end), it is at \(clip.bounds.minY)")
        let offset = clip.bounds.minY
        // As the app's bridge does: a select redraws the list in the same turn, before the drag goes on.
        model.onIntent = { [unowned model, unowned list] intent in
            model.apply(intent)
            list.reload(animated: false)
        }

        // A press on the second-to-last row switches to it, then moves past the drag threshold: the row lifts.
        list.leftButtonIsDown = { true }
        let pressed = ids[38]
        let at = try SidebarPointerGestureTests.point(list, .workspace(pressed))
        try SidebarPointerGestureTests.press(list, at: at, moves: [CGVector(dx: 0, dy: -10), CGVector(dx: 0, dy: -30)], release: false)
        try #require(list.drag != nil, "a 30 pt move did not lift the row")
        #expect(model.activeWorkspaceID == ids[0], "the drag did not put back the workspace shown before the press")
        #expect(abs(clip.bounds.minY - offset) < 0.5,
                "lifting the row scrolled the list from \(offset) to \(clip.bounds.minY): it jumped to the workspace shown before the press")
        list.cancelDrag()
        list.leftButtonIsDown = { false }
    }
}
