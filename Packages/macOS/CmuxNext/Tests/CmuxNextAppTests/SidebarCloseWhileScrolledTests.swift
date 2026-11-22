import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Two closes in quick succession in a scrolled sidebar (cx-y2uf5): the second, above the
/// viewport, re-anchors it (rows and offset shift together), while the first close's row is
/// still closing its slot. That row must shift with the rest, or it jumps by the shift against
/// its neighbors and keeps closing toward its old place.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarCloseWhileScrolledTests {
    /// The local machine's section with the workspaces `ids`.
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    @Test(.enabled("needs an awake display and animations on, or every close snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aRowStillClosingShiftsWithItsNeighborsWhenTheViewportReanchors() throws {
        let all = Array(1...40)
        let start = Self.sections(all)
        let ids = try #require(start.first?.workspaces.map(\.id))
        try #require(ids.count == all.count)
        let model = SidebarModel(sections: start, activeWorkspaceID: ids[0])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 320)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        defer { window.close() }
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        let list = sidebar.list
        list.reload(animated: false)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let clip = try #require(list.enclosingScrollView?.contentView)

        // Scrolled so workspace 20 is the first row in view.
        let top = try #require(list.displayed.row(for: .workspace(ids[19])))
        list.scrollClip(to: top.y, animated: false)
        try #require(abs(clip.bounds.minY - top.y) < 0.5, "the sidebar did not scroll to \(top.y), it is at \(clip.bounds.minY)")

        // Workspace 22, in view below the anchor, closes with motion: the viewport holds still.
        let closing = try #require(list.rowViews[.workspace(ids[21])])
        let neighbor = try #require(list.rowViews[.workspace(ids[20])])
        model.sections = Self.sections(all.filter { $0 != 22 })
        list.reload(animated: true)
        try #require(!list.rowViews.values.contains { $0 === closing })
        try #require(closing.superview === list && !closing.isHidden, "the closed row did not stay to close its slot")
        let gap = closing.frame.minY - neighbor.frame.minY
        let offset = clip.bounds.minY

        // Before that close ends, workspace 5, above the viewport, closes too: the viewport re-anchors.
        model.sections = Self.sections(all.filter { $0 != 22 && $0 != 5 })
        list.reload(animated: true)
        let shift = clip.bounds.minY - offset
        try #require(abs(shift) > 1, "closing a row above the viewport did not re-anchor it")
        try #require(list.rowViews[.workspace(ids[20])] === neighbor)

        // The closing row moved with its neighbor and the offset, not stayed at its old y.
        let now = closing.frame.minY - neighbor.frame.minY
        #expect(abs(now - gap) < 0.5,
                "the closing row is \(now) from its neighbor after the viewport shifted by \(shift), was \(gap): it jumped")
    }
}
