import CmuxNextCompat

/// The key press whose echo each of a surface's frames draws (p09-observability-102), so the frame's later
/// hook calls on other threads (its end on the renderer, its GPU completion on Metal's thread, its handoff)
/// mark the echo's `key.echo.renderer`, `key.echo.gpu_done` and `key.echo.contents` handoffs with the flow the
/// renderer took at the frame's begin. Fixed slots and atomics: a hook call never locks or allocates.
nonisolated extension GhosttyTraceHook.Surface {
    /// Frames whose echo flow a surface keeps at once (``frameFlows``): more than its swap chain has in flight.
    /// A power of two, so a frame's slot is its seq's low bits.
    static let frameFlowCapacity = 4

    /// The key press whose echo frame `seq` draws: slot `seq % frameFlowCapacity`, which a later frame overwrites.
    nonisolated final class FrameFlow: Sendable {
        let seq = Atomic<UInt64>(0)
        let flow = Atomic<UInt64>(0)
    }

    /// Frame `seq` draws the echo of key press `flow` (0: none, which leaves the slot as it is). The renderer
    /// thread, at the frame's begin.
    func noteFrame(seq: UInt64, flow: UInt64) {
        guard flow != 0 else { return }
        let slot = frameFlows[Self.slotIndex(seq)]
        slot.flow.store(flow, ordering: .relaxed)
        slot.seq.store(seq, ordering: .releasing)
    }

    /// The key press whose echo frame `seq` draws, 0 for none (or a frame whose slot a later one took).
    func frameFlow(seq: UInt64) -> UInt64 {
        let slot = frameFlows[Self.slotIndex(seq)]
        guard slot.seq.load(ordering: .acquiring) == seq else { return 0 }
        return slot.flow.load(ordering: .relaxed)
    }

    /// Frame `seq`'s slot in ``frameFlows``.
    private static func slotIndex(_ seq: UInt64) -> Int {
        Int(truncatingIfNeeded: seq) & (frameFlowCapacity - 1)
    }
}
