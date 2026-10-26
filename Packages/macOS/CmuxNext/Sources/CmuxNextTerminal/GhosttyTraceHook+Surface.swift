import CmuxNextCompat
import CmuxNextWakeups

extension GhosttyTraceHook {
    /// One surface's hook state, held by its ``SurfaceBridge`` until after `ghostty_surface_free` returns and
    /// found by the hook through its ``SurfaceTable`` entry. Its draws come from one thread at a time; its
    /// contents from main and the Metal completion thread, its GPU completions from the latter.
    nonisolated final class Surface: Sendable {
        /// Flows held at once for their frame's GPU completion: every press the probe tracks.
        static let gpuWaitCapacity = TypingLatencyProbe.openCapacity
        /// A slot's flow word while its holder writes the seq: no taker reads the slot.
        private static let claimed = UInt64.max

        let key: TypingLatencyProbe.SurfaceKey
        let echoStage: TerminalEchoStage?
        /// A `ghostty.render` begin was written and its end is due.
        let renderOpen = Atomic<Bool>(false)
        /// The newest frame whose contents were marked.
        private let markedContents = Atomic<UInt64>(0)
        /// Every frame below this seq finished its GPU work (one command queue: frames complete in order).
        private let gpuDoneBelow = Atomic<UInt64>(0)
        /// The address of the waits' words: wait `i`'s flow at word `2i` (0: free, ``claimed`` while held without
        /// its seq), its frame at `2i + 1`. Allocated in `init`, freed in `deinit`; kept as an integer so the class
        /// is `Sendable` with no unchecked claim (as `LaneStats`); every access goes through ``AtomicPointerSlot``.
        private let gpuWaitsAddress: UInt

        init(key: TypingLatencyProbe.SurfaceKey, echoStage: TerminalEchoStage?) {
            self.key = key
            self.echoStage = echoStage
            let words = UnsafeMutablePointer<UInt64>.allocate(capacity: 2 * Self.gpuWaitCapacity)
            words.initialize(repeating: 0, count: 2 * Self.gpuWaitCapacity)
            gpuWaitsAddress = UInt(bitPattern: words)
        }

        deinit {
            UnsafeMutablePointer<UInt64>(bitPattern: gpuWaitsAddress)?.deallocate()
        }

        /// Word `index` of the waits; below `2 * gpuWaitCapacity`.
        private func word(_ index: Int) -> AtomicPointerSlot {
            AtomicPointerSlot(UnsafeMutablePointer<UInt64>(bitPattern: gpuWaitsAddress).unsafelyUnwrapped + index)
        }

        private func flowWord(_ wait: Int) -> AtomicPointerSlot { word(2 * wait) }
        private func seqWord(_ wait: Int) -> AtomicPointerSlot { word(2 * wait + 1) }

        /// Whether `seq` is a frame newer than every frame marked so far, and marks it: a host-size change can
        /// report one frame twice, and only its first report counts.
        func takeFirstContents(_ seq: UInt64) -> Bool {
            var marked = markedContents.load(ordering: .relaxed)
            // wakeup-allow: bounded: a compare-exchange retry; it loops only when another thread marked a newer frame first.
            while seq > marked {
                let (exchanged, original) = markedContents.compareExchange(expected: marked, desired: seq, ordering: .relaxed)
                if exchanged { return true }
                marked = original
            }
            return false
        }

        /// Whether frame `seq`'s GPU work finished.
        func gpuFinished(_ seq: UInt64) -> Bool {
            gpuDoneBelow.load(ordering: .sequentiallyConsistent) > seq
        }

        /// Holds `flows` of frame `seq` for its GPU completion.
        ///
        /// - Returns: The flows to deliver now: those no wait was free for, and every held flow whose frame's GPU
        ///   work finished, in case its completion ran before these flows were held.
        func awaitGPU(_ flows: [UInt64], seq: UInt64) -> [UInt64] {
            var now: [UInt64] = []
            for flow in flows where !hold(flow, seq: seq) { now.append(flow) }
            return now + takeFinished()
        }

        /// Records that frame `seq`'s GPU work finished; returns the held flows of it and of earlier frames.
        func gpuDidFinish(seq: UInt64) -> [UInt64] {
            var below = gpuDoneBelow.load(ordering: .sequentiallyConsistent)
            // wakeup-allow: bounded: a compare-exchange retry; it loops only when another completion moved it first.
            while below <= seq {
                let (exchanged, original) = gpuDoneBelow.compareExchange(expected: below, desired: seq &+ 1,
                                                                         ordering: .sequentiallyConsistent)
                if exchanged { break }
                below = original
            }
            return takeFinished()
        }

        /// Puts `flow` of frame `seq` in a free wait; false when none is free. The flow is stored after its seq,
        /// sequentially consistent, and the completion stores ``gpuDoneBelow`` before it scans, likewise: of a
        /// hold and a completion that race, at least one sees the other, so ``takeFinished()`` runs for the flow.
        private func hold(_ flow: UInt64, seq: UInt64) -> Bool {
            for wait in 0..<Self.gpuWaitCapacity {
                let waiting = flowWord(wait)
                guard waiting.compareExchange(expected: 0, desired: Self.claimed, ordering: .sequentiallyConsistent).exchanged else { continue }
                seqWord(wait).store(seq, ordering: .relaxed)
                waiting.store(flow, ordering: .sequentiallyConsistent)
                return true
            }
            return false
        }

        /// Takes the held flows whose frame's GPU work finished; each flow goes to exactly one taker.
        private func takeFinished() -> [UInt64] {
            let below = gpuDoneBelow.load(ordering: .sequentiallyConsistent)
            var finished: [UInt64] = []
            for wait in 0..<Self.gpuWaitCapacity {
                let waiting = flowWord(wait)
                let flow = waiting.load(ordering: .sequentiallyConsistent)
                guard flow != 0, flow != Self.claimed else { continue }
                // The seq is this flow's or a later holder's; for a later holder the exchange fails, since a flow
                // is held once.
                guard seqWord(wait).load(ordering: .relaxed) < below,
                      waiting.compareExchange(expected: flow, desired: 0, ordering: .sequentiallyConsistent).exchanged else { continue }
                finished.append(flow)
            }
            return finished
        }
    }
}
