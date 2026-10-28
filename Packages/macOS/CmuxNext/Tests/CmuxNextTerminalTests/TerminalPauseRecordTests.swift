#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// v2.2.5-opt and v2.2.6-opt gates (handoff/v224-gate-triage.md): a visible terminal stayed paused `hidden` or
/// `window_occluded` while nothing hid or covered it, and drew nothing. Three unit orders did not reproduce it,
/// so the record keeps, per surface, the last pause computations (when, which caller, every input) and, when
/// read, what the pause would be now: a stale pause shows as `now` differing from the stored one. Record only.
@MainActor @Suite(.serialized) struct TerminalPauseRecordTests {
    @Test func eachComputationIsRecordedWithItsCallerAndInputs() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let drawsWhenOccluded = WindowDrawPolicy.drawsWhenOccluded, onScreen = WindowDrawPolicy.onScreen
        WindowDrawPolicy.drawsWhenOccluded = false
        WindowDrawPolicy.onScreen = { _ in false }
        defer {
            WindowDrawPolicy.drawsWhenOccluded = drawsWhenOccluded
            WindowDrawPolicy.onScreen = onScreen
        }
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
        window.contentView = session.view
        let surface = session.surfaceView
        #expect(surface.pause == .windowOccluded)

        let report = try #require(surface.pauseRecordReport)
        let last = try #require(report.computations.last)
        #expect(last.pause == "window_occluded")
        #expect(last.inputs.inWindow && !last.inputs.windowVisible && !last.inputs.hidden)
        #expect(!last.caller.isEmpty, "the record does not name the caller")
        #expect(report.now.pause == "window_occluded")
        #expect(!report.stale)

        // The window comes on screen and nothing recomputes: the record shows the stale pause.
        WindowDrawPolicy.onScreen = { _ in true }
        let stale = try #require(surface.pauseRecordReport)
        #expect(stale.now.pause == nil)
        #expect(stale.stale, "a stored pause that differs from what the inputs give now is not marked stale")
        #expect(surface.pause == .windowOccluded, "reading the record changed the pause (it must be record only)")
    }

    @Test func theRecordKeepsTheLastComputationsOnly() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer {
            io.finish()
            session.close()
        }
        let surface = session.surfaceView
        for _ in 0..<20 { surface.isRenderingSuspended.toggle() }
        let report = try #require(surface.pauseRecordReport)
        #expect(report.computations.count == TerminalPauseRecord.capacity)
    }
}
#endif
