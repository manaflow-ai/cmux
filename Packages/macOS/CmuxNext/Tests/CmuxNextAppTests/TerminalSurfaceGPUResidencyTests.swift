import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// p07-memory-037: a paused terminal away from the viewport lets its GPU memory go after the pause
/// reaches Ghostty, and gets it back before the occlusion change that draws its first frame on show.
/// One in the keep-alive band never lets it go.
@MainActor @Suite(.serialized) struct TerminalSurfaceGPUResidencyTests {
    /// A stand-in for the libghostty switch: each call, and whether Ghostty drew at that moment.
    final class RecordingResidency: TerminalGPUResidency {
        struct Call: Equatable {
            var resident: Bool
            /// `ghostty_surface_set_occlusion`'s last value when the call came (nil: never set).
            var drawing: Bool?
        }

        var calls: [Call] = []

        func setResident(_ resident: Bool, of view: TerminalSurfaceView) {
            calls.append(Call(resident: resident, drawing: view.lastOcclusionVisible))
        }
    }

    /// A drawing session in a window, with `residency` as its switch.
    private func shownSession(_ residency: RecordingResidency) throws -> (TerminalSession, NSWindow, ScriptedTerminalIO) {
        _ = NSApplication.shared
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, gpuResidency: residency)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        window.contentView = host
        session.view.frame = host.bounds
        host.addSubview(session.view)
        session.view.layoutSubtreeIfNeeded()
        try #require(session.surfaceView.lastOcclusionVisible == true, "the shown surface does not draw")
        return (session, window, io)
    }

    @Test func aHiddenPausedTerminalReleasesAfterThePauseAndIsResidentBeforeItDrawsAgain() throws {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let residency = RecordingResidency()
        let (session, window, io) = try shownSession(residency)
        defer {
            io.finish()
            window.close()
        }
        #expect(residency.calls.isEmpty, "a drawing surface changed its GPU residency: \(residency.calls)")

        // Hidden, away from the viewport (TabContentCache: the hide, then the ledger's away).
        session.isRenderingSuspended = true
        session.releasesGPUWhilePaused = true
        #expect(residency.calls == [.init(resident: false, drawing: false)], "hidden and paused: \(residency.calls)")
        #expect(session.pausedNonvolatileIOSurfaceBytes == 0, "a released surface still counts its swap chain")

        // Shown again (the reveal, then the ledger's back near the viewport).
        session.isRenderingSuspended = false
        session.releasesGPUWhilePaused = false
        #expect(residency.calls == [.init(resident: false, drawing: false), .init(resident: true, drawing: false)],
                "shown: the surface must be resident before Ghostty draws: \(residency.calls)")
        #expect(session.surfaceView.lastOcclusionVisible == true, "the shown surface does not draw")
    }

    @Test func aTerminalInTheKeepAliveBandStaysResidentWhilePaused() throws {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let residency = RecordingResidency()
        let (session, window, io) = try shownSession(residency)
        defer {
            io.finish()
            window.close()
        }

        // Off screen in the band: paused, never away; then scrolled back on screen.
        session.isRenderingSuspended = true
        #expect(session.pausedNonvolatileIOSurfaceBytes > 0, "a resident paused surface reports no swap chain")
        session.isRenderingSuspended = false
        #expect(session.pausedNonvolatileIOSurfaceBytes == 0, "a drawing surface counts as paused")
        #expect(residency.calls.isEmpty, "the keep-alive band changed GPU residency: \(residency.calls)")
    }

    @Test func aReplaySwapKeepsTheAwayStateAndADrawingSurfaceIsNeverReleased() async throws {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let residency = RecordingResidency()
        let (session, window, io) = try shownSession(residency)
        defer {
            io.finish()
            window.close()
        }
        // Away but drawing (a live hover mirror forces pixels): stays resident.
        session.mirrorDemand = 1
        session.isRenderingSuspended = true
        session.releasesGPUWhilePaused = true
        #expect(residency.calls.isEmpty, "a forced-drawing surface let its GPU memory go: \(residency.calls)")
        session.mirrorDemand = 0
        #expect(residency.calls == [.init(resident: false, drawing: false)], "mirror gone: \(residency.calls)")

        // A second replay swaps in a fresh surface: it is away too and releases once paused.
        let first = session.surfaceView
        io.send(.replay(Data("one".utf8)))
        io.send(.replay(Data("two".utf8)))
        let swappedBy = ContinuousClock.now.advanced(by: .seconds(5))
        while session.surfaceView === first, ContinuousClock.now < swappedBy { await Task.yield() }
        try #require(session.surfaceView !== first, "the replay did not swap the surface")
        #expect(session.surfaceView.releasesGPUWhilePaused, "the swapped-in surface lost the away state")
        #expect(residency.calls.filter { !$0.resident }.count == 2, "the fresh paused surface kept its GPU memory: \(residency.calls)")
        #expect(session.pausedNonvolatileIOSurfaceBytes == 0)
    }
}
