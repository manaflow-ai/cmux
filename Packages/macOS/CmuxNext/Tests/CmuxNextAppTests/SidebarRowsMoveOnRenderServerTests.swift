import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// Leo 2026-10-21: "right now adding a workspace at the top ... it pushes all the stuff down". The rows
/// below an insert make room on the render server's spring (`RowMotion.animate`, `SidebarDragSpring`): each
/// row's frame is at its slot at once and an additive spring carries what is on screen there, so the main
/// thread writes no row frame per display frame. AppKit's spring wrote every moving row's frame each frame.
@MainActor @Suite(.serialized)
struct SidebarRowsMoveOnRenderServerTests {
    /// The local machine's section with the workspaces `ids`, in that order.
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    /// The render server's position springs on `view`'s layer (`SidebarDragSpring` keys).
    private static func positionSprings(_ view: NSView) -> Int {
        (view.layer?.animationKeys() ?? []).filter { $0.hasPrefix("drag.position.") }.count
    }

    private static func sizeSprings(_ view: NSView) -> Int {
        (view.layer?.animationKeys() ?? []).filter { $0.hasPrefix("drag.size.") }.count
    }

    /// Workspaces 1 to `count` in a window on screen, the first selected, the list at its top, with new
    /// workspace rows opening (`ui.animations.newWorkspace`, off by default) and Reduce Motion off.
    private static func sidebar(count: Int) throws -> (SidebarModel, SidebarListView, NSWindow, restore: () -> Void) {
        let start = sections(Array(1...count))
        let model = SidebarModel(sections: start, activeWorkspaceID: try #require(start.first?.workspaces.first?.id))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let kinds = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        Motion.reduceMotionOverride = false
        return (model, sidebar.list, window, {
            Motion.reduceMotionOverride = nil
            DesignSettings.shared.enabledAnimations = kinds
            window.orderOut(nil)
        })
    }

    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func anInsertAtTheTopMovesTheRowsBelowOnTheRenderServer() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let clip = try #require(list.enclosingScrollView?.contentView)
        let shown = list.rowViews.compactMap { key, view -> (SidebarRowKey, SidebarRowView, CGFloat)? in
            if case .workspace = key { (key, view, view.frame.minY - clip.bounds.minY) } else { nil }
        }

        model.sections = Self.sections([0] + Array(1...30))
        list.reload(animated: true)

        // The rows the insert pushed down on screen (the list's top holds still, so all of them).
        var moved = 0
        for (key, view, wasOnScreen) in shown {
            let row = try #require(list.displayed.row(for: key))
            let slot = list.frame(for: row)
            guard abs(slot.minY - clip.bounds.minY - wasOnScreen) > 0.5 else { continue }
            moved += 1
            // The model frame is at the slot now: nothing moves it on the main thread later.
            #expect(view.frame == slot, "\(key) is at \(view.frame), its slot is \(slot)")
            #expect(Self.positionSprings(view) >= 1, "\(key) did not move on the render server")
        }
        #expect(moved > 3, "the insert at the top pushed \(moved) rows down (of \(shown.count) shown)")
        let added = try #require(Self.sections([0]).first?.workspaces.first?.id)
        let opening = try #require(list.rowViews[.workspace(added)], "the new row at the top has no view")
        let slot = try #require(list.displayed.row(for: opening.key).map(list.frame(for:)))
        #expect(opening.frame == slot, "the new row is at \(opening.frame), its slot is \(slot)")
        #expect(Self.sizeSprings(opening) >= 1, "the new row did not open its slot on the render server")
        #expect(opening.alphaValue < 1, "the new row showed whole in one frame")
    }

    /// A second insert while the first one's rows still move: each row keeps the first spring and adds one
    /// from where it is now, so nothing on screen jumps back to the first move's end.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aSecondInsertStacksOnTheFirstMove() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        let key = SidebarRowKey.workspace(try #require(Self.sections([1]).first?.workspaces.first?.id))
        let view = try #require(list.rowViews[key])

        model.sections = Self.sections([0] + Array(1...30))
        list.reload(animated: true)
        try #require(Self.positionSprings(view) == 1)
        model.sections = Self.sections([999, 0] + Array(1...30))
        list.reload(animated: true)

        #expect(list.rowViews[key] === view)
        #expect(Self.positionSprings(view) == 2, "the second move replaced the first one's spring (a jump)")
        let row = try #require(list.displayed.row(for: key))
        #expect(view.frame == list.frame(for: row))
    }

    /// The display goes to sleep mid-move: the rows drop their springs and stand at their slots.
    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aMoveTheDisplaySleepsThroughEndsAtTheSlots() throws {
        let (model, list, _, restore) = try Self.sidebar(count: 30)
        defer { restore() }
        model.sections = Self.sections([0] + Array(1...30))
        list.reload(animated: true)
        try #require(list.rowViews.values.contains { Self.positionSprings($0) > 0 })

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        defer { workspace.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared) }

        for (key, view) in list.rowViews {
            #expect(Self.positionSprings(view) == 0 && Self.sizeSprings(view) == 0, "\(key) still springs with the display asleep")
            let row = try #require(list.displayed.row(for: key))
            #expect(view.frame == list.frame(for: row) && view.alphaValue == 1, "\(key) did not end at its slot")
        }
    }
}
