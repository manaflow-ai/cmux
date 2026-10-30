import AppKit
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import Foundation
import Testing

/// A hidden workspace's terminals do no resize work (PL-script A3): every layout change of a hidden or
/// parked terminal used to size its Ghostty surface (`ghostty_surface_set_size`) and send its PTY a new
/// grid. Hidden, it records the size only; shown again, it applies the last size once.
@MainActor @Suite(.serialized) struct TerminalHiddenResizeTests {
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
}
