import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// While the display sleeps nothing draws, so an AppKit animation never advances: a sidebar row
/// inserted then (a session seeded over the socket) stayed at alpha 0 until Reduce Motion was
/// turned on. An animation completes or is skipped when nothing draws, and one already running
/// when the display goes to sleep ends at once.
@MainActor @Suite(.serialized)
struct SidebarInsertWhileDisplayAsleepTests {
    /// The local machine's section with the workspaces `ids`.
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    /// A display that is awake, with the animation speed not off: only there does a sidebar
    /// change animate, so only there can these tests tell motion from a snap.
    static func animatesHere() -> Bool {
        guard let screen = NSScreen.main, !DisplaySleep.shared.isAsleep(screen) else { return false }
        return Motion.speed != .off
    }

    /// A sidebar of workspaces 1 to 3 in a window on screen, the first selected.
    private static func sidebar() throws -> (SidebarModel, SidebarView, NSWindow) {
        let before = sections([1, 2, 3])
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

    /// Shows the workspaces `ids` (the selection stays, so new rows open with motion) and
    /// returns the last one's row.
    private static func show(_ ids: [Int], in model: SidebarModel, _ sidebar: SidebarView) throws -> SidebarRowView {
        let after = sections(ids)
        let last = try #require(after.first?.workspaces.last?.id)
        model.sections = after
        sidebar.list.reload(animated: true)
        return try #require(sidebar.list.rowViews[.workspace(last)])
    }

    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") { await Self.animatesHere() })
    func aRowInsertedWhileTheDisplaySleepsShowsWhole() throws {
        let (model, sidebar, window) = try Self.sidebar()
        defer { window.orderOut(nil) }
        try #require(window.screen != nil)
        // Synchronous from the sleep to the wake: both notifications are process-wide.
        let workspace = NSWorkspace.shared.notificationCenter
        Motion.reduceMotionOverride = false
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        defer {
            workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared)
            Motion.reduceMotionOverride = nil
        }

        let row = try Self.show([1, 2, 3, 4], in: model, sidebar)
        // No frame draws while the display sleeps: the row must be final now, not after one.
        #expect(row.alphaValue == 1, "the inserted row waits at alpha \(row.alphaValue) for a frame that never draws")
        #expect(row.frame.height > 0, "the inserted row waits at height \(row.frame.height) for a frame that never draws")
    }

    /// The display goes to sleep while a row opens and another closes: both end at once.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") { await Self.animatesHere() })
    func rowsStillMovingWhenTheDisplaySleepsEndAtOnce() throws {
        let (model, sidebar, window) = try Self.sidebar()
        defer { window.orderOut(nil) }
        try #require(window.screen != nil)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let list = sidebar.list

        // Workspace 2 leaves and workspace 4 arrives, with the display awake: both animate.
        let before = Set(list.rowViews.values.map(ObjectIdentifier.init))
        let opening = try Self.show([1, 3, 4], in: model, sidebar)
        let shown = Set(list.rowViews.values.map(ObjectIdentifier.init))
        let leaving = list.subviews.compactMap { $0 as? SidebarRowView }
            .filter { before.contains(ObjectIdentifier($0)) && !shown.contains(ObjectIdentifier($0)) }
        try #require(opening.alphaValue < 1, "the new row appeared in one frame with the display awake")
        try #require(leaving.count == 1, "the removed row did not stay to close its slot")

        // Synchronous from the sleep to the wake: both notifications are process-wide.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        defer { workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared) }

        // No frame draws from here: what was moving must be final now.
        #expect(opening.alphaValue == 1, "the opening row stopped at alpha \(opening.alphaValue)")
        #expect(opening.frame.height > 0, "the opening row stopped at height \(opening.frame.height)")
        #expect(leaving.allSatisfy { $0.superview == nil }, "the closing row stays in the list: its completion never ran")
    }

    /// The look with the display awake is unchanged: the new row still opens with motion.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") { await Self.animatesHere() })
    func aRowInsertedWhileTheDisplayIsAwakeStillOpens() throws {
        let (model, sidebar, window) = try Self.sidebar()
        defer { window.orderOut(nil) }
        try #require(window.screen != nil)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }

        let row = try Self.show([1, 2, 3, 4], in: model, sidebar)
        #expect(row.alphaValue < 1, "the inserted row appeared in one frame with the display awake")
    }
}
