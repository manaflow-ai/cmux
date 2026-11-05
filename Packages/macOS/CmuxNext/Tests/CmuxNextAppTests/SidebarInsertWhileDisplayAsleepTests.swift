import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// While the display sleeps nothing draws, so an AppKit animation never advances: a sidebar row
/// inserted then (a session seeded over the socket) stayed at alpha 0 until Reduce Motion was
/// turned on. An animation completes or is skipped when nothing draws, and one already running
/// when the display goes to sleep ends at once.
@MainActor @Suite(.serialized, .closesItsWindows)
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

    /// A new workspace row opens with motion only with `ui.animations.newWorkspace` on (off by
    /// default, hq-1d): each test turns it on, as it turns Reduce Motion off. Returns the restore.
    private static func newWorkspaceMotionOn() -> () -> Void {
        let kinds = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        return { DesignSettings.shared.enabledAnimations = kinds }
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

    /// A closing row whose completion ran: the list recycled it, which parks it hidden in place
    /// (dea9671b35d5/5763d7372701) or, out of the list, takes it out.
    private static func recycled(_ row: SidebarRowView) -> Bool { row.superview == nil || row.isHidden }

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
        defer { window.close() }
        let restoreKinds = Self.newWorkspaceMotionOn()
        defer { restoreKinds() }
        try #require(window.screen != nil)
        // Every display reads as asleep (Core Graphics decides in the app); synchronous to the reset.
        Motion.reduceMotionOverride = false
        DisplaySleep.asleepOverride = true
        defer {
            DisplaySleep.asleepOverride = nil
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
        defer { window.close() }
        let restoreKinds = Self.newWorkspaceMotionOn()
        defer { restoreKinds() }
        try #require(window.screen != nil)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let list = sidebar.list

        // Workspace 2 leaves and workspace 4 arrives, with the display awake: both animate.
        let before = Set(list.rowViews.values.map(ObjectIdentifier.init))
        let opening = try Self.show([1, 3, 4], in: model, sidebar)
        let shown = Set(list.rowViews.values.map(ObjectIdentifier.init))
        let leaving = list.subviews.compactMap { $0 as? SidebarRowView }
            .filter { before.contains(ObjectIdentifier($0)) && !shown.contains(ObjectIdentifier($0)) && !Self.recycled($0) }
        try #require(opening.alphaValue < 1, "the new row appeared in one frame with the display awake")
        try #require(leaving.count == 1, "the removed row did not stay to close its slot")

        // Synchronous from the sleep to the wake: both notifications are process-wide.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        defer { workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared) }

        // No frame draws from here: what was moving must be final now.
        #expect(opening.alphaValue == 1, "the opening row stopped at alpha \(opening.alphaValue)")
        #expect(opening.frame.height > 0, "the opening row stopped at height \(opening.frame.height)")
        #expect(leaving.allSatisfy(Self.recycled), "the closing row stays in the list: its completion never ran")
    }

    /// A change replayed at sleep never puts back what a newer reload changed: here the rows a
    /// reload moved since, and a view the pool gave to another row, keep their current places.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") { await Self.animatesHere() })
    func rowsANewerReloadPlacedKeepTheirPlacesWhenTheDisplaySleeps() throws {
        let (model, sidebar, window) = try Self.sidebar()
        defer { window.close() }
        let restoreKinds = Self.newWorkspaceMotionOn()
        defer { restoreKinds() }
        try #require(window.screen != nil)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let list = sidebar.list

        // Workspace 4 opens with motion; before it ends, two reloads without motion close
        // workspace 2 (its view goes back to the pool) and add workspace 5 (which can reuse it).
        let opening = try Self.show([1, 2, 3, 4], in: model, sidebar)
        try #require(opening.alphaValue < 1, "the new row appeared in one frame with the display awake")
        model.sections = Self.sections([1, 3, 4])
        list.reload(animated: false)
        model.sections = Self.sections([1, 3, 4, 5])
        list.reload(animated: false)

        // Synchronous from the sleep to the wake: both notifications are process-wide.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        defer { workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared) }

        for (key, view) in list.rowViews {
            let row = try #require(list.displayed.row(for: key))
            #expect(view.frame == list.frame(for: row), "\(key) went back to \(view.frame), not \(list.frame(for: row))")
            #expect(view.alphaValue == 1, "\(key) shows at alpha \(view.alphaValue)")
        }
    }

    /// A closing row whose animation outlived its replay window still leaves the list when
    /// AppKit ends the animation: the window only stops the replay, never the completion.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") { await Self.animatesHere() })
    func aClosingRowLeavesEvenAfterItsReplayExpired() async throws {
        let (model, sidebar, window) = try Self.sidebar()
        defer { window.close() }
        let restoreKinds = Self.newWorkspaceMotionOn()
        defer { restoreKinds() }
        try #require(window.screen != nil)
        Motion.reduceMotionOverride = false
        MotionInFlight.expirySlack = -100
        defer {
            MotionInFlight.expirySlack = 2
            Motion.reduceMotionOverride = nil
        }
        let list = sidebar.list

        // Workspace 2 closes with motion, its replay already expired; the next change sweeps it.
        let before = Set(list.rowViews.values.map(ObjectIdentifier.init))
        _ = try Self.show([1, 3], in: model, sidebar)
        let shown = Set(list.rowViews.values.map(ObjectIdentifier.init))
        let leaving = list.subviews.compactMap { $0 as? SidebarRowView }
            .filter { before.contains(ObjectIdentifier($0)) && !shown.contains(ObjectIdentifier($0)) && !Self.recycled($0) }
        try #require(leaving.count == 1, "the removed row did not stay to close its slot")
        _ = try Self.show([1, 3, 4], in: model, sidebar)

        try await Task.sleep(for: .seconds(1.5))
        #expect(leaving.allSatisfy(Self.recycled), "the closed row stays in the list: its completion was dropped")
    }

    /// The look with the display awake is unchanged: the new row still opens with motion.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") { await Self.animatesHere() })
    func aRowInsertedWhileTheDisplayIsAwakeStillOpens() throws {
        let (model, sidebar, window) = try Self.sidebar()
        defer { window.close() }
        let restoreKinds = Self.newWorkspaceMotionOn()
        defer { restoreKinds() }
        try #require(window.screen != nil)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }

        let row = try Self.show([1, 2, 3, 4], in: model, sidebar)
        #expect(row.alphaValue < 1, "the inserted row appeared in one frame with the display awake")
    }
}
