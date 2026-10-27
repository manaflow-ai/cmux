extension TypingLatencyProbe {
    /// The key presses whose echo one frame draws (``drawEchoes(on:)``), oldest first, in fixed storage: the
    /// renderer thread takes them at every frame's begin, so this never allocates. Chrome's compositor frame
    /// carries one `LatencyInfo` per input it covers the same way (`CompositorFrameMetadata::latency_info`,
    /// components/viz/common/quads/compositor_frame_metadata.h).
    public struct FrameEchoes: Sendable, Equatable, Sequence {
        /// Presses one frame names at most; a press past them is drawn by the frame with its handoffs unmarked.
        public static let capacity = 8

        /// The flows, 0 past ``count``.
        public private(set) var flows = SIMD8<UInt64>()
        /// How many flows the frame names.
        public private(set) var count = 0

        public init() {}

        /// The oldest press the frame draws (`ghostty.render`'s flow), 0 for none.
        public var oldest: UInt64 { count > 0 ? flows[0] : 0 }

        /// Adds `flow` (nonzero) after the ones before it; nothing once ``capacity`` are named.
        public mutating func append(_ flow: UInt64) {
            guard flow != 0, count < Self.capacity else { return }
            flows[count] = flow
            count += 1
        }

        public func makeIterator() -> Iterator { Iterator(echoes: self) }

        /// The flows in order.
        public struct Iterator: IteratorProtocol {
            let echoes: FrameEchoes
            var index = 0

            public mutating func next() -> UInt64? {
                guard index < echoes.count else { return nil }
                defer { index += 1 }
                return echoes.flows[index]
            }
        }
    }
}
