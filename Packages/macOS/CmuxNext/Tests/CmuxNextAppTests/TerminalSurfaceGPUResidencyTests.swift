import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import GhosttyNextKit
import Testing

/// A paused terminal away from the viewport lets its GPU memory go after the pause
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
        GhosttyRuntime.startedForTests()
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()), gpuResidency: residency)
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
        // The swap chain's two buffers besides the presented frame, which is volatile while paused.
        let size = ghostty_surface_size(try #require(session.surfaceView.surface))
        #expect(session.pausedNonvolatileIOSurfaceBytes == UInt64(size.width_px) * UInt64(size.height_px) * 4 * 2)
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

        // A replay swaps in a fresh surface while the mirror still draws: it is never released, not even
        // for one turn (the draw demand reaches it before the away state).
        let first = session.surfaceView
        try await swap(session, io, replays: ["one", "two"])
        try #require(session.surfaceView !== first, "the replay did not swap the surface")
        #expect(residency.calls.isEmpty, "a swap under a live mirror released or restored the fresh surface: \(residency.calls)")

        session.mirrorDemand = 0
        #expect(residency.calls == [.init(resident: false, drawing: false)], "mirror gone: \(residency.calls)")

        // Another replay swaps in a fresh surface: it is away too and releases once paused.
        let second = session.surfaceView
        try await swap(session, io, replays: ["three"])
        try #require(session.surfaceView !== second, "the replay did not swap the surface")
        #expect(session.surfaceView.releasesGPUWhilePaused, "the swapped-in surface lost the away state")
        #expect(residency.calls.filter { !$0.resident }.count == 2, "the fresh paused surface kept its GPU memory: \(residency.calls)")
        #expect(!residency.calls.contains { $0.resident }, "a paused away surface was made resident: \(residency.calls)")
        #expect(session.pausedNonvolatileIOSurfaceBytes == 0)
    }

    /// A parked workspace's container (``ParkingContainer``): off screen while it stays in its window.
    final class ParkingHost: NSView, ParkingContainer {
        var isParkedOffScreen = false
    }

    /// A GPU-released terminal in a parked workspace gets no scale or display call from a
    /// backing change (each wakes its parked renderer thread); shown again, it applies its display once.
    @Test func aParkedReleasedTerminalSendsNoDisplayCallOnABackingChange() throws {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let residency = RecordingResidency()
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()), gpuResidency: residency)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        session.releasesGPUWhilePaused = true
        let parking = ParkingHost(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        parking.isParkedOffScreen = true
        session.view.frame = parking.bounds
        parking.addSubview(session.view)
        let window = NSWindow(contentRect: parking.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            window.close()
        }
        window.contentView = parking
        let screen = try #require(window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                                  "the window is on no screen")

        session.surfaceView.viewDidChangeBackingProperties()
        #expect(session.surfaceView.appliedDisplayID == nil, "a parked terminal got a display call")
        #expect(residency.calls == [.init(resident: false, drawing: false)], "parked and away: \(residency.calls)")

        // Shown: resident before it draws, and its display applied once.
        session.releasesGPUWhilePaused = false
        parking.isParkedOffScreen = false
        parking.notifyParkingChange()
        #expect(session.surfaceView.appliedDisplayID == screen.uint32Value, "the shown terminal has no display")
        #expect(residency.calls.last == .init(resident: true, drawing: false), "shown: \(residency.calls)")
    }

    /// Sends `replays` and waits (5 s at most) until the session swapped in a new surface.
    private func swap(_ session: TerminalSession, _ io: ScriptedTerminalIO, replays: [String]) async throws {
        let before = session.surfaceView
        for replay in replays { io.send(.replay(Data(replay.utf8))) }
        let swappedBy = ContinuousClock.now.advanced(by: .seconds(5))
        while session.surfaceView === before, ContinuousClock.now < swappedBy { await Task.yield() }
    }
}
