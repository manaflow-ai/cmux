import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextFeed
import Foundation
import Testing

/// The right sidebar cleanup (Lawrence and Leo, 2026-10-21): every section sits on the same ground
/// (the window's, no panel of another color), the sidebar resizes by dragging its edge facing the
/// content and keeps that width for the next window, and it starts minimal: hidden, narrow.
@MainActor @Suite(.serialized)
struct RightSidebarCleanupTests {
    private struct Harness {
        let services: AppServices
        let controller: WindowController
        let defaults: UserDefaults
        let suite: String

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let suite = "cmux-right-sidebar-cleanup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        services.rightSidebarDefaults = defaults
        services.windows.ordersWindowsIn = false
        AppActions.bind(services)
        let controller = try #require(services.windows.openWindow(workspaces: ["rsc-workspace"]))
        return Harness(services: services, controller: controller, defaults: defaults, suite: suite)
    }

    // MARK: One ground

    /// The Feed section painted the pane's fill under its list while every other section shows the
    /// window's ground: a panel of another gray in the sidebar.
    @Test func theFeedSectionPaintsNoGroundOfItsOwn() throws {
        let h = try Self.harness()
        defer { h.close() }
        #expect(h.services.registry.perform("switchRightSidebarToFeed", invocation: ActionInvocation(origin: .cli)))
        let feed = try #require(h.controller.root.rightPanel?.shownSection as? FeedHostView)
        feed.updateLayer()
        let ground = feed.appearanceState.colors.background
        #expect(NSColor(ground).alphaComponent == 0, "the sidebar's Feed paints \(NSColor(ground))")
        #expect((feed.layer?.backgroundColor?.alpha ?? 0) == 0)
    }

    /// The Feed's own panel and page tab keep their grounds.
    @Test func theFeedPanelAndPageKeepTheirGround() {
        _ = NSApplication.shared
        for surface in [FeedHostView.Surface.page, .panel] {
            let feed = FeedHostView(model: FeedModel(source: MockFeedSource()), surface: surface)
            feed.updateLayer()
            let ground = NSColor(feed.appearanceState.colors.background).alphaComponent
            #expect(ground > 0, "\(surface) lost its ground")
        }
    }

    /// No section draws a ground: rendered alone, an empty corner of each stays transparent, so the
    /// window's ground shows the same under every section.
    @Test(arguments: RightSidebarMode.allCases)
    func noSectionDrawsAGround(_ mode: RightSidebarMode) throws {
        let h = try Self.harness()
        defer { h.close() }
        guard h.services.registry.perform(mode.actionID, invocation: ActionInvocation(origin: .cli)) else { return }
        let root = h.controller.root
        root.layoutSubtreeIfNeeded()
        let section = try #require(root.rightPanel?.shownSection)
        section.layoutSubtreeIfNeeded()
        section.displayIfNeeded()
        let rep = try #require(section.bitmapImageRepForCachingDisplay(in: section.bounds))
        section.cacheDisplay(in: section.bounds, to: rep)
        // The bottom corner, under any rows or empty-state text.
        let corner = try #require(rep.colorAt(x: 4, y: rep.pixelsHigh - 4))
        #expect(corner.alphaComponent < 0.02, "\(mode) paints \(corner) under its content")
    }

    // MARK: Resizable

    /// Dragging the edge facing the content widens or narrows the sidebar live, the main pane
    /// follows, the width stays inside its range, and the next window opens at it.
    @Test func draggingTheInnerEdgeResizesAndTheNextWindowKeepsTheWidth() throws {
        let h = try Self.harness()
        defer { h.close() }
        let root = h.controller.root
        #expect(h.services.registry.perform("toggleRightSidebar"))
        root.layoutSubtreeIfNeeded()
        let panel = try #require(root.rightPanel)
        let start = panel.frame.width
        let fullWidth = root.contentHost.frame.width + start
        let handle = panel.resizeHandle
        // The sidebar is on the right: its edge facing the content is its left edge.
        let edge = root.convert(handle.frame, from: panel)
        #expect(edge.minX <= panel.frame.minX + 1 && edge.maxX >= panel.frame.minX, "the handle is not on the inner edge")
        let hit = root.hitTest(root.convert(NSPoint(x: edge.midX, y: edge.midY), to: root.superview))
        #expect(hit === handle, "a press on the inner edge reaches \(String(describing: hit))")

        try Self.drag(handle, by: -60)
        root.layoutSubtreeIfNeeded()
        #expect(panel.frame.width == start + 60, "a 60 pt drag left made it \(panel.frame.width) pt")
        #expect(root.contentHost.frame.width == fullWidth - start - 60, "the main pane did not give room")
        #expect(h.controller.rightSidebar.width == start + 60)

        try Self.drag(handle, by: 5000)
        root.layoutSubtreeIfNeeded()
        #expect(panel.frame.width == RightSidebarModel.widthRange.lowerBound, "narrowed past its range to \(panel.frame.width)")
        try Self.drag(handle, by: -5000)
        root.layoutSubtreeIfNeeded()
        #expect(panel.frame.width == RightSidebarModel.widthRange.upperBound, "widened past its range to \(panel.frame.width)")

        try Self.drag(handle, by: RightSidebarModel.widthRange.upperBound - start - 40)
        let next = try #require(h.services.windows.openWindow(workspaces: ["rsc-workspace-2"]))
        next.root.layoutSubtreeIfNeeded()
        #expect(next.rightSidebar.width == start + 40)
        #expect(next.root.rightPanel?.frame.width == start + 40, "the next window opened at \(next.root.rightPanel?.frame.width ?? 0)")
    }

    // MARK: Minimal by default

    /// A first launch: no sidebar, and when it opens, a narrow one.
    @Test func itStartsHiddenAndNarrow() throws {
        let suite = "cmux-right-sidebar-fresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RightSidebarModel(defaults: defaults)
        #expect(!model.isVisible)
        #expect(model.width == RightSidebarModel.width)
        #expect(RightSidebarModel.width <= 260, "the default width is \(RightSidebarModel.width)")
    }

    /// The section bar is icons only: no bezel, no pressed-in state; the shown section's icon is
    /// the one in full ink, the others are dimmed.
    @Test func theSectionBarIsIconsOnly() throws {
        let h = try Self.harness()
        defer { h.close() }
        #expect(h.services.registry.perform("switchRightSidebarToDock"))
        let panel = try #require(h.controller.root.rightPanel)
        let buttons = panel.barButtons
        #expect(!buttons.isEmpty)
        for (mode, button) in buttons {
            #expect(!button.isBordered && button.title.isEmpty, "\(mode) draws a bezel or title")
            #expect(button.state == .off, "\(mode) shows a pressed-in state")
            #expect(button.alphaValue == (mode == .dock ? 1 : RightSidebarView.idleButtonAlpha), "\(mode) alpha \(button.alphaValue)")
        }
    }

    private static func drag(_ handle: NSView, by dx: CGFloat) throws {
        let window = try #require(handle.window)
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        handle.mouseDown(with: try event(.leftMouseDown, start.x))
        handle.mouseDragged(with: try event(.leftMouseDragged, start.x + dx / 2))
        handle.mouseDragged(with: try event(.leftMouseDragged, start.x + dx))
        handle.mouseUp(with: try event(.leftMouseUp, start.x + dx))
    }
}
