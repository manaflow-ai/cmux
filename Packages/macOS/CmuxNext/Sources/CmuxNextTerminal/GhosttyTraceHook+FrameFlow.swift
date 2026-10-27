import CmuxNextCompat
import CmuxNextWakeups

/// The key presses whose echo each of a surface's frames draws (p09-observability-102), so the frame's later
/// hook calls on other threads (its end on the renderer, its GPU completion on Metal's thread, its handoff)
/// mark the `key.echo.renderer`, `key.echo.gpu_done` and `key.echo.contents` handoffs of every press the
/// renderer took at the frame's begin. Fixed slots and atomics: a hook call never locks or allocates.
nonisolated extension GhosttyTraceHook.Surface {
    /// Frames whose echo flows a surface keeps at once (``frameFlows``): more than its swap chain has in flight.
    /// A power of two, so a frame's slot is its seq's low bits.
    static let frameFlowCapacity = 4

    /// The key presses whose echo frame `seq` draws: slot `seq % frameFlowCapacity`, which a later frame
    /// overwrites. `tag` is the frame's seq + 1, 0 while the renderer rewrites the flows.
    nonisolated final class FrameFlow: Sendable {
        /// One flow of the frame, 0 for none.
        nonisolated final class Cell: Sendable {
            let flow = Atomic<UInt64>(0)
        }

        let tag = Atomic<UInt64>(0)
        let cells: [Cell] = (0..<TypingLatencyProbe.FrameEchoes.capacity).map { _ in Cell() }
    }

    /// Frame `seq` draws the echoes of `echoes` (none leaves the slot as it is). The renderer thread, at the
    /// frame's begin; the only writer of the surface's slots.
    func noteFrame(seq: UInt64, echoes: TypingLatencyProbe.FrameEchoes) {
        guard echoes.count > 0 else { return }
        let slot = frameFlows[Self.slotIndex(seq)]
        // A reader that sees any of the new flows sees the slot as rewritten (``frameEchoes(seq:)`` checks the tag
        // again), so it never pairs an older frame's seq with this frame's flows.
        slot.tag.store(0, ordering: .releasing)
        for index in slot.cells.indices {
            slot.cells[index].flow.store(echoes.flows[index], ordering: .releasing)
        }
        slot.tag.store(seq &+ 1, ordering: .releasing)
    }

    /// The key presses whose echo frame `seq` draws, oldest first; none for a frame that draws no echo, or whose
    /// slot a later frame took.
    func frameEchoes(seq: UInt64) -> TypingLatencyProbe.FrameEchoes {
        let slot = frameFlows[Self.slotIndex(seq)]
        guard slot.tag.load(ordering: .acquiring) == seq &+ 1 else { return TypingLatencyProbe.FrameEchoes() }
        var echoes = TypingLatencyProbe.FrameEchoes()
        for cell in slot.cells {
            echoes.append(cell.flow.load(ordering: .acquiring))
        }
        guard slot.tag.load(ordering: .acquiring) == seq &+ 1 else { return TypingLatencyProbe.FrameEchoes() }
        return echoes
    }

    /// Frame `seq`'s slot in ``frameFlows``.
    private static func slotIndex(_ seq: UInt64) -> Int {
        Int(truncatingIfNeeded: seq) & (frameFlowCapacity - 1)
    }
}
