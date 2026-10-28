import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// Recipe R-hide in the terminal (PL-ghostty): a surface is shown by its node, under its
/// tab's node, not by an ancestor walk. Its tab unselected or its workspace hidden makes it not shown with no
/// AppKit change; AppKit hiding it forwards to the same node; an occluded window keeps it shown (its own
/// occlusion watch pauses the drawing).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalSurfaceVisibilityTests {
    @Test func theSurfaceIsShownByItsTabsNode() {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = ScriptedTerminalIO()
        let tab = VisibilityNode(root: "tab", own: .visible)
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: tab)
        defer {
            io.finish()
            session.close()
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        let surface = session.surfaceView
        #expect(surface.isShown, "a terminal in a window under a visible tab is not shown")

        tab.set(.hidden)
        #expect(!surface.isShown, "a terminal whose tab hid is still shown")
        tab.set(.occluded)
        #expect(surface.isShown, "an occluded terminal stopped keeping its layout ready")
        tab.set(.visible)
        #expect(surface.isShown)

        session.view.isHidden = true
        #expect(surface.visibilityNode.own == .hidden, "AppKit's hide did not reach the surface's node")
        #expect(!surface.isShown)
        session.view.isHidden = false
        #expect(surface.visibilityNode.own == .visible)
        #expect(surface.isShown)

        tab.set(.hidden)
        session.view.isHidden = true
        session.view.isHidden = false
        #expect(!surface.isShown, "an AppKit unhide showed a terminal whose tab is hidden")
        tab.set(.visible)
        #expect(surface.isShown)
    }

    /// A terminal with no tab (tests, previews) has a root node of its own: it is shown while it is in a window.
    @Test func aSurfaceWithoutATabNodeIsShownInAWindow() {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer {
            io.finish()
            session.close()
        }
        #expect(!session.surfaceView.isShown, "a terminal in no window is shown")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        #expect(session.surfaceView.isShown, "a terminal with no tab node is not shown in its window")
        #expect(session.surfaceView.visibilityNode.parent == nil)
    }

    /// What a hidden terminal skips waits on its node under a key, not in a flag: a forced report and a
    /// resize while its tab is hidden send one grid on show, in either order, and leave nothing waiting.
    @Test func aForcedReportAndAResizeWhileHiddenReportOnceOnShow() {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let reports = GridReportLog()
        let io = MainGridIO(reports: reports)
        let tab = VisibilityNode(root: "tab", own: .visible)
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: tab)
        defer { session.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        let surface = session.surfaceView
        #expect(surface.windowNode.deferredCount == 0, "a shown terminal kept work waiting")

        tab.set(.hidden)
        var before = reports.grids.count
        surface.updateSurfaceSize(forceReport: true)
        surface.setFrameSize(NSSize(width: 500, height: 300))
        #expect(reports.grids.count == before, "a hidden terminal reported its grid")
        #expect(surface.windowNode.deferredCount == 2)
        tab.set(.visible)
        #expect(reports.grids.count == before + 1, "a forced report and a resize sent \(reports.grids.count - before) grids on show")
        #expect(reports.grids.last == surface.fittedGrid)
        #expect(surface.windowNode.deferredCount == 0 && surface.visibilityNode.deferredCount == 0)

        tab.set(.hidden)
        before = reports.grids.count
        surface.setFrameSize(NSSize(width: 640, height: 400))
        surface.updateSurfaceSize(forceReport: true)
        #expect(surface.windowNode.deferredCount == 1, "a forced report did not take the place of the pending size")
        tab.set(.visible)
        #expect(reports.grids.count == before + 1)
        #expect(surface.windowNode.deferredCount == 0)
    }

    // MARK: A replay's surface swap into a parked tab (v2.2.5-opt: a terminal beside Home stayed paused "hidden")

    /// v2.2.5-opt launch smoke (handoff/v224-gate-triage.md): a terminal tab's surface stayed paused `hidden` and
    /// drew nothing, though AppKit did not hide it. A replay swaps the surface (`TerminalSession.swapSurface`): the
    /// fresh surface goes into the session's host view. When that host is parked (`PaneContentView.retire` hid
    /// it: the tab is not shown), the fresh surface joins a hidden view; the pane then shows the tab again by
    /// unhiding the host (`install`). The fresh surface must draw.
    @Test func aSurfaceSwappedInWhileItsTabIsParkedDrawsWhenTheTabShows() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let drawsWhenOccluded = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drawsWhenOccluded }
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                      node: VisibilityNode(root: "tab", own: .visible))
        defer {
            io.finish()
            session.close()
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let contentHost = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = contentHost
        session.view.frame = contentHost.bounds
        contentHost.addSubview(session.view)
        let first = session.surfaceView
        try #require(first.pause == nil, "the first surface does not draw: \(String(describing: first.pause))")

        session.view.isHidden = true // PaneContentView.retire: the tab is parked
        session.swapSurface() // a replay into a surface with content
        let fresh = session.surfaceView
        try #require(fresh !== first && fresh.window === window)
        session.view.isHidden = false // PaneContentView.install: the tab shows again

        #expect(!fresh.isHiddenOrHasHiddenAncestor)
        #expect(fresh.pause == nil, "the swapped-in surface stayed paused \(String(describing: fresh.pause)) in a shown tab")
        #expect(fresh.isShown, "the swapped-in surface is not shown in a shown tab")
    }
}

/// The grids a session reported, in its main-actor turn (``MainGridIO``).
@MainActor private final class GridReportLog {
    var grids: [TerminalGridSize] = []
}

/// A ``TerminalIO`` that takes every grid on the main actor, so a test reads the reports in the same turn.
private nonisolated final class MainGridIO: TerminalIO {
    let events = AsyncStream<TerminalIOEvent> { $0.finish() }
    let reports: GridReportLog

    init(reports: GridReportLog) {
        self.reports = reports
    }

    func write(_ data: Data) async {}

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}

    @MainActor func resizeOnMain(cols: Int, rows: Int, final: Bool, window: NSWindow?) -> Bool {
        reports.grids.append(TerminalGridSize(columns: cols, rows: rows))
        return true
    }
}
