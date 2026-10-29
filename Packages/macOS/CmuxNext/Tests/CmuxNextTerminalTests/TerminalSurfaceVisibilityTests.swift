import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import GhosttyNextKit
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

    /// A terminal that is not shown keeps no queued size work (principled-audit R2): its size is its bounds,
    /// read when it shows. A new owner and resizes while its tab is hidden, in either order, report nothing
    /// while hidden and the grid of its bounds once on show; nothing waits on its nodes at any time.
    @Test func aNewOwnerAndResizesWhileHiddenReportTheShownGridOnceOnShow() {
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
        surface.reportToNewOwner()
        surface.setFrameSize(NSSize(width: 500, height: 300))
        surface.setFrameSize(NSSize(width: 520, height: 310))
        #expect(reports.grids.count == before, "a hidden terminal reported its grid")
        #expect(surface.windowNode.deferredCount == 0, "a hidden terminal queued work")
        tab.set(.visible)
        #expect(reports.grids.count == before + 1, "a new owner and two resizes sent \(reports.grids.count - before) grids on show")
        #expect(reports.grids.last == Self.fit(surface), "the grid sent on show is not the one its bounds fit")
        #expect(surface.restingGridMismatch(onScreen: true, ownerSettled: false) == nil)
        #expect(surface.windowNode.deferredCount == 0 && surface.visibilityNode.deferredCount == 0)

        tab.set(.hidden)
        before = reports.grids.count
        surface.setFrameSize(NSSize(width: 640, height: 400))
        surface.reportToNewOwner()
        tab.set(.visible)
        #expect(reports.grids.count == before + 1)
        #expect(reports.grids.last == Self.fit(surface), "the grid sent on show is not the one its bounds fit")

        // Shown again at the size it had when it hid: the owner has that grid, nothing is sent.
        tab.set(.hidden)
        before = reports.grids.count
        tab.set(.visible)
        #expect(reports.grids.count == before, "a show with no change sent a grid")
    }

    /// The grid Ghostty fits the surface's bounds to, read from Ghostty itself (not the view's own record).
    private static func fit(_ surface: TerminalSurfaceView) -> TerminalGridSize? {
        guard let ghostty = surface.surface else { return nil }
        let pixels = surface.convertToBacking(surface.bounds.size)
        var columns: UInt16 = 0, rows: UInt16 = 0
        guard ghostty_surface_fit_grid(ghostty, UInt32(pixels.width), UInt32(pixels.height), &columns, &rows) else { return nil }
        return TerminalGridSize(columns: Int(columns), rows: Int(rows))
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
