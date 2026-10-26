import CmuxNextCompat

extension TypingLatencyProbe {
    /// One terminal surface's open key presses: a fixed ring of flow ids, one atomic word each (0 when
    /// free). The key router opens a press here when it hands the key to the surface
    /// (``TypingLatencyProbe/keyReachedTerminal(_:)``); the surface's output lane and frame mark by it.
    public final class SurfaceFlows: Sendable {
        /// Presses one surface tracks at once; a newer one overwrites the oldest slot.
        public static let capacity = 8

        private final class Slot: Sendable {
            let flow = Atomic<UInt64>(0)
        }

        private let slots: [Slot]
        private let next = Atomic<UInt32>(0)

        public init() {
            slots = (0..<Self.capacity).map { _ in Slot() }
        }

        func open(_ flow: UInt64) {
            guard flow != 0, !contains(flow) else { return }
            let index = Int(next.wrappingAdd(1, ordering: .relaxed).oldValue % UInt32(Self.capacity))
            slots[index].flow.store(flow, ordering: .relaxed)
        }

        func close(_ flow: UInt64) {
            for slot in slots { slot.flow.compareExchange(expected: flow, desired: 0, ordering: .relaxed) }
        }

        func contains(_ flow: UInt64) -> Bool {
            slots.contains { $0.flow.load(ordering: .relaxed) == flow }
        }

        /// Calls `body` with each open flow.
        func forEachOpen(_ body: (UInt64) -> Void) {
            for slot in slots {
                let flow = slot.flow.load(ordering: .relaxed)
                if flow != 0 { body(flow) }
            }
        }
    }
}
