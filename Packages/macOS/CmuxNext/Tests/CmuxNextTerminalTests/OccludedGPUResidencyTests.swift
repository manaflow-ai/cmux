import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// A terminal shown in a window that stays off screen (minimized, another Space, covered by
/// the app's own window) lets its GPU memory go after ``WindowDrawPolicy/offScreenGPUReleaseDelay``, one
/// deadline armed when the window's occlusion changes, and is resident again before Ghostty draws when the
/// window comes back. Fake seams: the window's visibility, the deadline and the libghostty switch.
@MainActor @Suite(.serialized) struct OccludedGPUResidencyTests {
    /// A stand-in for the libghostty switch: each call, and whether Ghostty drew at that moment.
    final class RecordingResidency: TerminalGPUResidency {
        struct Call: Equatable {
            var resident: Bool
            /// `ghostty_surface_set_occlusion`'s last value when the call came.
            var drawing: Bool?
        }

        var calls: [Call] = []
        /// The deadline it gave each surface, in creation order.
        var deadlines: [ManualDeadline] = []

        func setResident(_ resident: Bool, of view: TerminalSurfaceView) {
            calls.append(Call(resident: resident, drawing: view.lastOcclusionVisible))
        }

        func makeOffScreenDeadline() -> (any TerminalOffScreenDeadline)? {
            let deadline = ManualDeadline()
            deadlines.append(deadline)
            return deadline
        }
    }

    /// A deadline the test fires.
    final class ManualDeadline: TerminalOffScreenDeadline {
        private(set) var delays: [Duration] = []
        private var fire: (@MainActor () -> Void)?
        var isPending: Bool { fire != nil }

        func schedule(after delay: Duration, _ fire: @escaping @MainActor () -> Void) {
            delays.append(delay)
            self.fire = fire
        }

        func cancel() { fire = nil }

        func elapse() {
            let fire = fire
            self.fire = nil
            fire?()
        }
    }

    /// Which windows are off screen (``WindowDrawPolicy/onScreen``).
    final class Screens {
        var offScreen: Set<ObjectIdentifier> = []
    }

    /// One window of `count` drawing terminals, each with its own deadline, on the fake screen.
    struct Rig {
        let window: NSWindow
        let sessions: [TerminalSession]
        let ios: [ScriptedTerminalIO]
        let screens: Screens
        let residency: RecordingResidency?

        /// Each surface's deadline (none without the switch).
        var deadlines: [ManualDeadline] { residency?.deadlines ?? [] }

        /// The paused surfaces' non-volatile swap chains (`debug.memory` hidden_nonvolatile_iosurface_bytes).
        var hiddenBytes: UInt64 { sessions.reduce(0) { $0 + $1.pausedNonvolatileIOSurfaceBytes } }

        /// The window is minimized or deminiaturized, and AppKit's occlusion notice reaches each shown surface
        /// (`TerminalSurfaceView.windowStateChanged` runs `updateOcclusion`; the view observes the process's
        /// center, so the test calls the handler instead of posting there).
        func minimize(_ offScreen: Bool) {
            if offScreen { screens.offScreen.insert(ObjectIdentifier(window)) } else { screens.offScreen.remove(ObjectIdentifier(window)) }
            for session in sessions { session.surfaceView.updateOcclusion() }
        }

        func close() {
            ios.forEach { $0.finish() }
            window.close()
        }
    }

    /// The draw policy's seams as a test found them; ``restore()`` puts them back.
    struct PolicySnapshot {
        let drawsWhenOccluded = WindowDrawPolicy.drawsWhenOccluded
        let onScreen = WindowDrawPolicy.onScreen

        func restore() {
            WindowDrawPolicy.drawsWhenOccluded = drawsWhenOccluded
            WindowDrawPolicy.onScreen = onScreen
        }
    }

    private func makeRig(terminals count: Int = 1, residency: RecordingResidency? = RecordingResidency()) throws -> Rig {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let screens = Screens()
        WindowDrawPolicy.drawsWhenOccluded = false
        WindowDrawPolicy.onScreen = { !screens.offScreen.contains(ObjectIdentifier($0)) }
        let width = CGFloat(240 * count)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 240))
        window.contentView = host
        var sessions: [TerminalSession] = [], ios: [ScriptedTerminalIO] = []
        for index in 0..<count {
            let io = ScriptedTerminalIO()
            let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()), gpuResidency: residency)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            session.view.frame = NSRect(x: CGFloat(240 * index), y: 0, width: 240, height: 240)
            host.addSubview(session.view)
            session.view.layoutSubtreeIfNeeded()
            try #require(session.surfaceView.lastOcclusionVisible == true, "the shown surface does not draw")
            sessions.append(session)
            ios.append(io)
        }
        return Rig(window: window, sessions: sessions, ios: ios, screens: screens, residency: residency)
    }

    @Test func offScreenThirtySecondsReleasesAndVisibleIsResidentBeforeRender() throws {
        let policy = PolicySnapshot()
        defer { policy.restore() }
        let rig = try makeRig()
        defer { rig.close() }
        let session = rig.sessions[0]
        let deadline = try #require(rig.deadlines.first, "the switch made no deadline")
        let residency = try #require(rig.residency)

        rig.minimize(true)
        #expect(session.surfaceView.pause == .windowOccluded)
        #expect(deadline.delays == [WindowDrawPolicy.offScreenGPUReleaseDelay], "the notice armed no 30 s deadline")
        #expect(WindowDrawPolicy.offScreenGPUReleaseDelay == .seconds(30))
        #expect(residency.calls.isEmpty, "released before the window stayed off screen: \(residency.calls)")
        #expect(session.isInOffScreenWindow)
        #expect(rig.hiddenBytes > 0, "a resident paused surface reports no swap chain")

        deadline.elapse()
        #expect(residency.calls == [.init(resident: false, drawing: false)], "off screen 30 s: \(residency.calls)")
        #expect(rig.hiddenBytes == 0, "a released surface still counts its swap chain")

        // The notice again while off screen arms nothing more (one-shot).
        rig.minimize(true)
        #expect(deadline.delays.count == 1 && !deadline.isPending)

        rig.minimize(false)
        #expect(residency.calls == [.init(resident: false, drawing: false), .init(resident: true, drawing: false)],
                "shown: the surface must be resident before Ghostty draws: \(residency.calls)")
        #expect(session.surfaceView.lastOcclusionVisible == true, "the shown surface does not draw")
        #expect(!session.isInOffScreenWindow)
    }

    @Test func backBeforeTheDelayCancelsAndKeepsTheGPUMemory() throws {
        let policy = PolicySnapshot()
        defer { policy.restore() }
        let rig = try makeRig()
        defer { rig.close() }
        let deadline = try #require(rig.deadlines.first, "the switch made no deadline")
        let residency = try #require(rig.residency)

        rig.minimize(true)
        #expect(deadline.isPending)
        rig.minimize(false)
        #expect(!deadline.isPending, "the window came back and the deadline stayed armed")
        #expect(residency.calls.isEmpty, "a short trip off screen changed GPU residency: \(residency.calls)")

        // Off screen again: a fresh 30 s.
        rig.minimize(true)
        #expect(deadline.delays.count == 2 && deadline.isPending)
    }

    /// A scripted tab or workspace switch in a window that stayed off screen hides (or parks) its released
    /// terminal: a surface in the keep-alive band (`releasesGPUWhilePaused` false) stays released, since nobody
    /// sees it, and shown again in that window it stays released too. Only a window on screen makes it resident,
    /// before Ghostty draws.
    @Test func hidingAReleasedSurfaceInAnOffScreenWindowKeepsItReleased() throws {
        let policy = PolicySnapshot()
        defer { policy.restore() }
        let rig = try makeRig()
        defer { rig.close() }
        let session = rig.sessions[0]
        let deadline = try #require(rig.deadlines.first, "the switch made no deadline")
        let residency = try #require(rig.residency)
        #expect(!session.surfaceView.releasesGPUWhilePaused, "the surface is not in the keep-alive band")

        rig.minimize(true)
        deadline.elapse()
        #expect(residency.calls == [.init(resident: false, drawing: false)])

        session.view.isHidden = true
        #expect(session.surfaceView.pause == .hidden)
        #expect(residency.calls == [.init(resident: false, drawing: false)],
                "a switch in a minimized window made a hidden surface resident: \(residency.calls)")
        #expect(!deadline.isPending, "a hidden surface armed a deadline")

        session.view.isHidden = false
        #expect(session.surfaceView.pause == .windowOccluded)
        #expect(residency.calls == [.init(resident: false, drawing: false)],
                "shown again in the minimized window: \(residency.calls)")
        #expect(!deadline.isPending, "a released surface armed a second deadline")

        rig.minimize(false)
        #expect(residency.calls == [.init(resident: false, drawing: false), .init(resident: true, drawing: false)],
                "deminiaturized: the surface must be resident before Ghostty draws: \(residency.calls)")
        #expect(session.surfaceView.lastOcclusionVisible == true)
    }

    /// A window fully covered by an opaque cmux window (its occlusion family) counts too.
    @Test func aWindowCoveredByTheAppsOwnWindowReleasesAfterTheDelay() throws {
        let policy = PolicySnapshot()
        defer { policy.restore() }
        let rig = try makeRig()
        defer { rig.close() }
        let deadline = try #require(rig.deadlines.first, "the switch made no deadline")
        let residency = try #require(rig.residency)
        let family = WindowOcclusionFamily.of(rig.window)

        family.set(occluded: true)
        #expect(deadline.isPending, "the family's flip armed no deadline")
        deadline.elapse()
        #expect(residency.calls == [.init(resident: false, drawing: false)])
        family.set(occluded: false)
        #expect(residency.calls.last == .init(resident: true, drawing: false), "uncovered: \(residency.calls)")
        #expect(rig.sessions[0].surfaceView.lastOcclusionVisible == true)
    }

    /// Without the libghostty switch (`terminalGPURelease` off, or an older pin) no deadline is armed at all.
    @Test func noSwitchArmsNoDeadline() throws {
        let policy = PolicySnapshot()
        defer { policy.restore() }
        let rig = try makeRig(residency: nil)
        defer { rig.close() }

        rig.minimize(true)
        #expect(rig.sessions[0].surfaceView.pause == .windowOccluded)
        #expect(!rig.sessions[0].surfaceView.offScreenRelease.isArmed, "a surface that cannot release armed a deadline")
    }

    /// One minimized window of six terminals: after the delay none holds a non-volatile swap chain.
    @Test func aMinimizedWindowOfSixTerminalsHoldsNoHiddenSwapChain() throws {
        let policy = PolicySnapshot()
        defer { policy.restore() }
        let rig = try makeRig(terminals: 6)
        defer { rig.close() }
        let residency = try #require(rig.residency)

        rig.minimize(true)
        #expect(rig.sessions.allSatisfy { $0.isInOffScreenWindow })
        #expect(rig.hiddenBytes > 0)
        #expect(rig.deadlines.allSatisfy { $0.isPending })
        rig.deadlines.forEach { $0.elapse() }
        #expect(rig.hiddenBytes == 0, "hidden_nonvolatile_iosurface_bytes \(rig.hiddenBytes) in a minimized window")
        #expect(residency.calls == Array(repeating: RecordingResidency.Call(resident: false, drawing: false), count: 6))

        rig.minimize(false)
        #expect(residency.calls.filter { $0.resident }.count == 6, "deminiaturized: \(residency.calls)")
        #expect(residency.calls.allSatisfy { $0.drawing == false }, "a surface drew before it was resident: \(residency.calls)")
        #expect(rig.sessions.allSatisfy { $0.surfaceView.lastOcclusionVisible == true })
    }
}
