import AppKit
import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Foundation
import Testing

/// A hidden workspace's terminals do no resize work (PL-script A3): every layout change of a hidden or
/// parked terminal used to size its Ghostty surface (`ghostty_surface_set_size`) and send its PTY a new
/// grid. Hidden, it records the size only; shown again, it applies the last size once.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalHiddenResizeTests {
    @Test func layoutChangesOfAHiddenTerminalSizeNothingUntilItIsShownThenOnce() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = GridRecordingTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = workspace
        session.view.frame = workspace.bounds
        workspace.addSubview(session.view)
        defer {
            io.finish()
            window.close()
        }
        workspace.layoutSubtreeIfNeeded()
        func grids() async -> [TerminalGridSize] {
            session.surfaceView.bridge.takeUnretainedValue().input.focusGained()
            return await io.gridsUntilMarker()
        }
        _ = await grids()
        let shownFit = try #require(session.diagnostics.fitGrid)

        workspace.isHidden = true
        for step in 1...20 {
            session.view.frame = NSRect(x: 0, y: 0, width: 900 - CGFloat(step) * 13, height: 600 - CGFloat(step) * 7)
            workspace.layoutSubtreeIfNeeded()
        }
        let hiddenReports = await grids()
        #expect(hiddenReports.isEmpty, "20 hidden layout changes sent the PTY \(hiddenReports.count) grids")
        #expect(session.diagnostics.fitGrid == shownFit, "a hidden layout change sized the Ghostty surface")

        workspace.isHidden = false
        workspace.layoutSubtreeIfNeeded()
        let shownReports = await grids()
        let fit = try #require(session.diagnostics.fitGrid)
        #expect(fit != shownFit, "showing it did not apply the size it took while hidden")
        #expect(shownReports == [fit], "showing it sent \(shownReports), not its grid \(fit) once")
    }

    /// T-KEYS (frame-owner-s4): a hide drops the grid that waits in the coalescer's 25 ms window
    /// (`cancelGridReport`). Shown again at the same size, the view sends its grid once, the newest, as a grid at rest
    /// (the coalescer skips one the PTY has). A hide and show with no change sends nothing: no PTY resize per tab switch.
    @Test func aHideDuringAGridWindowSendsTheNewestGridOnceWhenShownAndAHideWithNoChangeSendsNothing() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = GridRecordingTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = workspace
        session.view.frame = workspace.bounds
        workspace.addSubview(session.view)
        defer {
            io.finish()
            window.close()
        }
        workspace.layoutSubtreeIfNeeded()
        func grids() async -> [TerminalGridSize] {
            session.surfaceView.bridge.takeUnretainedValue().input.focusGained()
            return await io.gridsUntilMarker()
        }
        _ = await grids()

        // No change: hide, show, nothing goes.
        workspace.isHidden = true
        workspace.isHidden = false
        workspace.layoutSubtreeIfNeeded()
        let unchanged = await grids()
        #expect(unchanged.isEmpty, "a hide and show with no change sent the PTY \(unchanged)")

        // A key resize the host follows: each size is live. Two sizes in one turn, then the hide in the same turn (no
        // await: no refresh or 25 ms window can end in between). While its refresh sent nothing, the first grid goes at
        // once (RESIZE P0 7); else it waits in the coalescer's window. This rig's window is not on screen, so its
        // presenter may never tick to clear the refresh the last send spent: both paths are exact here, and the at-once
        // rule itself is TerminalGridReportCoalescerTests (10) and (11). The second size waits in the window either way.
        let coalescer = session.surfaceView.gridReports.coalescer
        let sentBefore = coalescer.lastSent
        session.view.followPaneMotion(PaneMotionHold(trailing: false, bottom: false), heldSize: session.view.bounds.size)
        session.view.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        workspace.layoutSubtreeIfNeeded()
        let first = try #require(session.surfaceView.fittedGrid)
        try #require(first != sentBefore, "the 760x520 size did not change the grid (\(first))")
        let wentAtOnce = coalescer.lastSent == first
        #expect(wentAtOnce ? !coalescer.isWaiting : coalescer.pending == first,
                "the first grid neither went nor waits (sent \(String(describing: coalescer.lastSent)))")
        let atOnce = wentAtOnce ? [first] : []
        session.view.frame = NSRect(x: 0, y: 0, width: 700, height: 480)
        workspace.layoutSubtreeIfNeeded()
        let newest = try #require(session.surfaceView.fittedGrid)
        try #require(coalescer.pending == newest,
                     "the followed resize did not leave its newest grid \(newest) waiting (pending \(String(describing: coalescer.pending)))")
        workspace.isHidden = true
        #expect(!coalescer.isWaiting, "the hide left the grid waiting")
        session.view.followPaneMotion(nil, heldSize: nil)
        workspace.layoutSubtreeIfNeeded()
        let hidden = await grids()
        #expect(hidden == atOnce, "the dropped window or the hidden view sent \(hidden) (before the hide: \(atOnce))")

        // Shown again at the same size: the newest grid goes, once.
        workspace.isHidden = false
        workspace.layoutSubtreeIfNeeded()
        let shown = await grids()
        #expect(shown == [newest], "shown again it sent \(shown), not the newest grid \(newest) once")
    }

    /// frame-owner-s2's rule for the grid a hidden view keeps for its show (`resendsShownGrid`): a newer grid that goes
    /// while the view is hidden (a spring's final grid, or a forced report) must never be followed by an older grid. A
    /// hide drops a waiting grid (the flag is set); then the newer grid goes; then the view shows at its size. The PTY's
    /// last grid is the grid the view fits, and the show sends at most one grid.
    @Test(arguments: [false, true])
    func aGridKeptForTheShowNeverGoesAfterANewerGrid(newerIsForced: Bool) async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = GridRecordingTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = workspace
        session.view.frame = workspace.bounds
        workspace.addSubview(session.view)
        defer {
            io.finish()
            window.close()
        }
        workspace.layoutSubtreeIfNeeded()
        func grids() async -> [TerminalGridSize] {
            session.surfaceView.bridge.takeUnretainedValue().input.focusGained()
            return await io.gridsUntilMarker()
        }
        _ = await grids()

        // A followed key resize leaves a grid waiting (its second size in one turn: the first went at once, RESIZE P0 7);
        // the hide drops it and keeps a grid for the show.
        session.view.followPaneMotion(PaneMotionHold(trailing: false, bottom: false), heldSize: session.view.bounds.size)
        session.view.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        workspace.layoutSubtreeIfNeeded()
        session.view.frame = NSRect(x: 0, y: 0, width: 700, height: 480)
        workspace.layoutSubtreeIfNeeded()
        let coalescer = session.surfaceView.gridReports.coalescer
        try #require(coalescer.isWaiting, "SETUP: the followed resize left no grid waiting")
        workspace.isHidden = true
        session.view.followPaneMotion(nil, heldSize: nil)
        workspace.layoutSubtreeIfNeeded()
        try #require(session.surfaceView.resendsShownGrid, "SETUP: the hide kept no grid for the show")

        // A newer grid goes while hidden.
        if newerIsForced {
            session.surfaceView.updateSurfaceSize(forceReport: true)
        } else {
            session.surfaceView.reportFinalGrid(TerminalGridSize(columns: 40, rows: 12))
        }
        let hidden = await grids()

        workspace.isHidden = false
        workspace.layoutSubtreeIfNeeded()
        let shown = await grids()
        let fit = try #require(session.surfaceView.fittedGrid)
        let last = (hidden + shown).last
        print("hidden grid kept for the show, newer \(newerIsForced ? "forced" : "final"): hidden \(hidden), shown \(shown), fit \(fit)")
        #expect(last == fit, "the PTY's last grid is \(String(describing: last)), not the view's fit \(fit): an older grid went after a newer one")
        #expect(shown.count <= 1, "the show sent \(shown.count) grids: \(shown)")
    }

    /// Review of 5840aea3a603, P1 #2: a grid a hide drops is not lost when the view shows again during a spring. During a
    /// key spring G1 waits in the coalescer's window while the PTY has G0; the view is hidden (the hide drops G1), shown
    /// again while it is still in its pane's motion, and the spring lands at G1. Before the fix the geometry counted G1 as
    /// reported, so neither the show nor the landing sent it, and the PTY stayed at G0.
    /// A pane on its layout spring while `onSpring` (``RestingPlacement``): what the app's pane host is during a key spring.
    @MainActor final class SpringPlacement: NSView, RestingPlacement {
        var onSpring = false
        var restOffset: CGVector { .zero }
        var isOnLayoutSpring: Bool { onSpring }
        var restContentSizeChange: CGSize? { nil }
    }

    @Test func aGridAHideDropsReachesThePTYWhenTheViewShowsDuringASpringAndLands() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = GridRecordingTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let workspace = SpringPlacement(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = workspace
        session.view.frame = workspace.bounds
        workspace.addSubview(session.view)
        defer {
            io.finish()
            window.close()
        }
        workspace.layoutSubtreeIfNeeded()
        func grids() async -> [TerminalGridSize] {
            session.surfaceView.bridge.takeUnretainedValue().input.focusGained()
            return await io.gridsUntilMarker()
        }
        let start = await grids()
        let g0 = try #require(start.last ?? session.surfaceView.fittedGrid, "SETUP: no grid at rest")

        // The key spring: the host follows its pane; its first size's grid goes at once (RESIZE P0 7), and the next size's
        // grid G1, in the same refresh, waits in the window.
        let surface = session.surfaceView
        workspace.onSpring = true
        session.view.followPaneMotion(PaneMotionHold(trailing: false, bottom: false), heldSize: session.view.bounds.size)
        session.view.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        workspace.layoutSubtreeIfNeeded()
        session.view.frame = NSRect(x: 0, y: 0, width: 700, height: 480)
        workspace.layoutSubtreeIfNeeded()
        let g1 = try #require(surface.fittedGrid)
        try #require(g1 != g0 && surface.gridReports.coalescer.pending == g1,
                     "SETUP: G1 \(g1) does not wait in the window (pending \(String(describing: surface.gridReports.coalescer.pending)), G0 \(g0))")
        // Hidden: G1 is dropped. Shown again while still in the spring.
        workspace.isHidden = true
        workspace.isHidden = false
        workspace.layoutSubtreeIfNeeded()
        try #require(surface.isInPaneMotion, "SETUP: the view is not in its pane's motion at the show")
        // The spring lands at G1.
        session.view.followPaneMotion(nil, heldSize: nil)
        workspace.onSpring = false
        surface.paneMotionDidSettle()
        workspace.layoutSubtreeIfNeeded()
        let after = await grids()
        print("hide during a spring: G0 \(g0), G1 \(g1), grids after the hide \(after)")
        #expect(after.last == g1, "the PTY ends at \(String(describing: after.last ?? start.last)), not G1 \(g1): the grid the hide dropped was lost")
    }
}
