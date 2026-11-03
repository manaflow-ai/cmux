import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// A one-tab workspace released in its own sidebar slot makes no document change, but must end
/// the gap preview. Exercise the app's drag session and real window; no display is a failure.
@MainActor @Suite(.serialized, .closesItsWindows,
                 .enabled(if: !NSScreen.screens.isEmpty || ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1",
                          "the drag tests need a display"))
struct SidebarTabGapCleanupTests {
    @Test(arguments: [true, false])
    func releasingTheOnlyTabClearsTheSidebarGap(release: Bool) async throws {
        _ = NSApplication.shared
        try #require(!NSScreen.screens.isEmpty, "this regression requires a GUI fleet worker")
        let keys = ["k0", "k2"]
        var tree = SidebarMultiViewWindowTests.Fixture.tree(keys)
        for index in tree.workspaces.indices {
            let id = UInt64(index + 1)
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [
                TabSnapshot(surface: SurfaceID(rawValue: id), title: "Terminal"),
            ])
            tree.workspaces[index].screens = [ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(pane.id), panes: [pane])]
            tree.workspaces[index].name = index == 0 ? "Single tab source" : "Gap neighbor"
        }
        let f = try await SidebarMultiViewWindowTests.Fixture(keys: keys, tree: tree)
        defer { f.close() }
        let window = try #require(f.controller.window)
        let sidebar = f.controller.sidebar.container.sidebarView
        let neighbor = SidebarRowKey.workspace(WorkspaceID("k2"))
        let before = try #require(f.list.rowViews[neighbor]).frame
        let row = try #require(f.list.displayed.row(for: neighbor))
        let point = f.list.convert(NSPoint(x: 80, y: row.y + 1), to: nil)
        let source = try #require(f.controller.content?.panes.values.first)
        try #require(source.pane.tabs.count == 1)
        let tab = try #require(source.pane.tabs.first)
        let strip = source.view.stripView
        let frame = window.convertToScreen(strip.convert(strip.bounds, to: nil))
        let start = TabDragStart(tabID: CmuxNextTabs.TabID(tab.id), stripID: source.stripModel.stripID,
                                 screenFrame: CGRect(x: frame.minX, y: frame.minY, width: 120, height: frame.height),
                                 grabOffset: CGPoint(x: 20, y: 10), screenPoint: CGPoint(x: frame.minX + 20, y: frame.minY + 10), snapshot: nil)
        let session = f.services.dragSession
        session.begin(start, from: source)
        _ = session.handle(try f.event(.leftMouseDragged, at: point))
        // The display link opens the real slot after its dwell; wait on that result, not a fixed delay.
        let opened = try await Self.waitUntil {
            f.frame()
            return f.list.displayed.gapY != nil
        }
        try #require(opened, "the drag never opened a gap")
        let drag = try #require(session.drag)
        try #require(drag.source.context.emptiesSourceWorkspace)
        guard case .moveWorkspace = drag.outcome else {
            Issue.record("the only tab did not resolve to a workspace move: \(drag.outcome)")
            return
        }
        try #require(f.list.displayed.gapY != nil, "the drag never opened a gap")
        let heldNeighbor = try #require(f.list.rowViews[neighbor])
        try #require(heldNeighbor.frame.minY > before.minY)
        try Self.capture(sidebar, phase: release ? "held-release" : "held-cancel")

        if release {
            _ = session.handle(try f.event(.leftMouseUp, at: point))
        } else {
            session.finish(commit: false)
        }
        session.finishLanding()
        let settled = try await Self.waitUntil {
            f.frame()
            guard f.list.external == nil, f.list.displayed.gapY == nil,
                  let neighborView = f.list.rowViews[neighbor] else { return false }
            let y = neighborView.layer?.presentation()?.frame.minY ?? neighborView.frame.minY
            let ring = sidebar.dropOutlineView?.ring.layer
            return abs(y - before.minY) < 0.5 && (ring?.presentation()?.opacity ?? ring?.opacity ?? 0) == 0
        }
        try Self.capture(sidebar, phase: release ? "released" : "cancelled")
        #expect(settled, "the gap and neighbor did not return to rest")
        #expect(!session.isDragging)
        #expect(f.list.drag == nil)
        #expect(f.list.external == nil, "the ended tab drag still owns a gap")
        #expect(f.list.displayed.gapY == nil, "the empty placeholder survived the release")
        #expect(sidebar.dropOutlineView?.ring.layer.opacity == 0, "the drop outline survived the release")
        let after = try #require(f.list.rowViews[neighbor]).frame
        #expect(abs(after.minY - before.minY) < 0.5, "the neighbor stayed displaced by \(after.minY - before.minY) pt")
        #expect(f.model.sections.flatMap(\.workspaces).map(\.id.rawValue) == keys,
                "dropping in the source's own slot changed the workspace rows")
        #expect(source.pane.tabs.count == 1, "the terminal moved out of its source")
    }

    /// AppKit's display-link and compositor completion have no awaitable signal here.
    /// The deadline bounds only failure; successful runs return as soon as the rendered state settles.
    private static func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private static func capture(_ sidebar: SidebarView, phase: String) throws {
        let output = AANestedGroupsGalleryTests.packageRoot.appending(path: "sidebar-tab-gap-cleanup-gallery")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try #require(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
        sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appending(path: "\(phase).png"))
    }
}
