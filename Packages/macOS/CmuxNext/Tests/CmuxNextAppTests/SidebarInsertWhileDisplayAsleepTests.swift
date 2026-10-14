import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// While the display sleeps nothing draws, so an AppKit animation never advances: a sidebar row
/// inserted then (a session seeded over the socket) stayed at alpha 0 until Reduce Motion was
/// turned on. An animation completes or is skipped when nothing draws.
@MainActor @Suite(.serialized)
struct SidebarInsertWhileDisplayAsleepTests {
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

    /// A sidebar of 3 workspaces in a window on screen, the first selected.
    private static func sidebar() throws -> (SidebarModel, SidebarView, NSWindow) {
        let before = sections(count: 3)
        let model = SidebarModel(sections: before, activeWorkspaceID: try #require(before.first?.workspaces.first?.id))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 320)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return (model, sidebar, window)
    }

    /// Adds workspace 4 (not selected, so the row opens with motion) and returns its row.
    private static func insert(into model: SidebarModel, _ sidebar: SidebarView) throws -> SidebarRowView {
        let after = sections(count: 4)
        let added = try #require(after.first?.workspaces.last?.id)
        model.sections = after
        sidebar.list.reload(animated: true)
        return try #require(sidebar.list.rowViews[.workspace(added)])
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aRowInsertedWhileTheDisplaySleepsShowsWhole() throws {
        let (model, sidebar, window) = try Self.sidebar()
        defer { window.orderOut(nil) }
        try #require(window.screen != nil)
        try #require(Motion.canAnimate(in: sidebar.list), "the display is already asleep on this host")
        // Synchronous from the sleep to the wake: both notifications are process-wide.
        let workspace = NSWorkspace.shared.notificationCenter
        Motion.reduceMotionOverride = false
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        defer {
            workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared)
            Motion.reduceMotionOverride = nil
        }
        // With the animation speed off every insert is instant, and this would pass without the fix.
        try #require(Motion.animatesMovement, "animation speed is off on this host")

        let row = try Self.insert(into: model, sidebar)
        // No frame draws while the display sleeps: the row must be final now, not after one.
        #expect(row.alphaValue == 1, "the inserted row waits at alpha \(row.alphaValue) for a frame that never draws")
        #expect(row.frame.height > 0, "the inserted row waits at height \(row.frame.height) for a frame that never draws")
    }

    /// The look with the display awake is unchanged: the new row still opens with motion.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aRowInsertedWhileTheDisplayIsAwakeStillOpens() throws {
        let (model, sidebar, window) = try Self.sidebar()
        defer { window.orderOut(nil) }
        try #require(window.screen != nil)
        try #require(Motion.canAnimate(in: sidebar.list), "the display is asleep on this host")
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.animatesMovement, "animation speed is off on this host")

        let row = try Self.insert(into: model, sidebar)
        #expect(row.alphaValue < 1, "the inserted row appeared in one frame with the display awake")
    }
}
