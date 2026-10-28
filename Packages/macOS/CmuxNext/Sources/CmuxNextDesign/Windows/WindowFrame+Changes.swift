#if DEBUG || CMUX_BENCH_HOOKS
nonisolated extension WindowFrame {
    /// Each frame's share of pixels that differ from the frame before it; the first frame's is 0.
    @concurrent public static func changes(_ frames: [WindowFrame]) async -> [Double] {
        guard let first = frames.first else { return [] }
        var previous = first
        return frames.map { frame in
            defer { previous = frame }
            return frame.difference(from: previous)
        }
    }
}
#endif
