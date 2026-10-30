import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// cx-evo3q: with ~24 workspaces, Cmd-N's new row landed below the viewport and the list slid
/// to it for +107..+279 ms beside content that had already switched. The polish bar is
/// "instant": a selected new row appears in place (cx-8g3sn), and the list shows it at once.
@MainActor @Suite(.closesItsWindows)
struct SidebarNewRowInPlaceTests {
    /// The local machine's section with workspaces 1 through `count`.
    private static func sections(count: Int) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: (1...count).map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// The list scrolls in a window on screen: with no screen Motion snaps it.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aNewWorkspaceBelowTheViewportShowsWithoutASlide() throws {
        let before = Self.sections(count: 24)
        let model = SidebarModel(sections: before, activeWorkspaceID: try #require(before.first?.workspaces.first?.id))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 320)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let clip = sidebar.scrollView.contentView
        let after = Self.sections(count: 25)
        let added = try #require(after.first?.workspaces.last?.id)
        // Cmd-N: the new row and its selection reach the list in one turn (SidebarSelectionHold).
        let (row, shown) = try { () throws -> (NSRect, NSRect) in
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            // With the animation speed off every scroll is instant, and this would pass with the slide.
            try #require(Motion.sidebar.animatesMovement, "animation speed is off on this host")
            model.sections = after
            model.activeWorkspaceID = added
            sidebar.list.reload(animated: true)
            let view = try #require(sidebar.list.rowViews[.workspace(added)])
            return (view.frame, clip.bounds)
        }()
        #expect(row.minY >= shown.minY && row.maxY <= shown.maxY,
                "the list slid to the new row: row \(row), shown \(shown)")
    }
}
