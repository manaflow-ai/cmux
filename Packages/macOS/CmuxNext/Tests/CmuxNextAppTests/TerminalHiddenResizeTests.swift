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
    /// A font size change resizes a shown terminal at once and a hidden one when it is shown (a config
    /// reload changes every terminal's font, the warm hidden ones too): one PTY grid each, at the size
    /// it shows at.
    @Test func aFontSizeChangeResizesAShownTerminalAtOnceAndAHiddenOneWhenShown() async throws {
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

        #expect(session.surfaceView.performBindingAction("increase_font_size:2"))
        let shown = await grids()
        #expect(shown.count == 1, "a shown terminal's font change sent \(shown), not one grid")

        workspace.isHidden = true
        let before = session.diagnostics.fitGrid
        for _ in 1...3 { #expect(session.surfaceView.performBindingAction("increase_font_size:2")) }
        let hidden = await grids()
        #expect(hidden.isEmpty, "a hidden terminal's font changes sent the PTY \(hidden.count) grids")
        #expect(session.diagnostics.fitGrid == before, "a hidden font change sized the Ghostty surface")

        workspace.isHidden = false
        workspace.layoutSubtreeIfNeeded()
        let revealed = await grids()
        let fit = try #require(session.diagnostics.fitGrid)
        #expect(fit != before, "showing it did not apply the font change it got while hidden")
        #expect(revealed == [fit], "showing it sent \(revealed), not its grid \(fit) once")
    }
}
