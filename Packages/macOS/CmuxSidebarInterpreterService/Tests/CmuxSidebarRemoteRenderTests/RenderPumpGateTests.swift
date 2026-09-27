import Testing
@testable import CmuxSidebarRemoteRender

/// Behavior of the display pump's dirtiness gate: invalidations arm it (and
/// say when the paused display link must resume), dirty ticks pump, the pump's
/// commit cleans it, and the first clean tick pauses the link so an idle
/// worker costs nothing.
@Suite struct RenderPumpGateTests {
    @Test func firstInvalidationDemandsALinkResume() {
        var gate = RenderPumpGate()
        let mustResume = gate.markDirty()
        #expect(mustResume)
        #expect(gate.isDirty)
    }

    @Test func invalidationsCoalesceWhileDirty() {
        var gate = RenderPumpGate()
        let first = gate.markDirty()
        #expect(first)
        // Already armed: a flood of needsLayout/needsDisplay flips during one
        // frame must not keep re-resuming the link.
        let second = gate.markDirty()
        let third = gate.markDirty()
        #expect(!second)
        #expect(!third)
        #expect(gate.isDirty)
    }

    @Test func dirtyTickPumpsAndCleanTickPauses() {
        var gate = RenderPumpGate()
        _ = gate.markDirty()
        #expect(gate.tickAction() == .pump)
        gate.pumpCompleted()
        // Nothing new since the commit: the next tick parks the link.
        #expect(gate.tickAction() == .pause)
    }

    @Test func commitAbsorbsInvalidationsRaisedDuringThePump() {
        var gate = RenderPumpGate()
        _ = gate.markDirty()
        #expect(gate.tickAction() == .pump)
        // Layout inside the pump re-marks the view dirty before the commit;
        // that work is flushed by the same CATransaction.flush, so completion
        // returns the gate to clean instead of scheduling a redundant pump.
        _ = gate.markDirty()
        gate.pumpCompleted()
        #expect(!gate.isDirty)
        #expect(gate.tickAction() == .pause)
    }

    @Test func explicitMessagePumpClearsPendingDirtinessWithoutATick() {
        var gate = RenderPumpGate()
        _ = gate.markDirty()
        // A host message (scene/geometry/pointer) pumps synchronously; its
        // commit also flushes whatever armed the gate, so the link's next
        // tick pauses instead of double-pumping.
        gate.pumpCompleted()
        #expect(gate.tickAction() == .pause)
    }

    @Test func invalidationAfterACommitRearms() {
        var gate = RenderPumpGate()
        _ = gate.markDirty()
        gate.pumpCompleted()
        // The clean -> dirty transition must resume the link again.
        let mustResume = gate.markDirty()
        #expect(mustResume)
        #expect(gate.tickAction() == .pump)
    }

    @Test func idleGateStaysClean() {
        let gate = RenderPumpGate()
        #expect(!gate.isDirty)
        #expect(gate.tickAction() == .pause)
    }
}
