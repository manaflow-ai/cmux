extension RenderStats {
    /// Frames a producer presented itself, counted from any thread: each one is a ``Counter/contentsSets`` of its
    /// owner while the stats count, nothing otherwise (one atomic load), and nothing in Release, which
    /// has no hooks. Held by the producer for the process (``RenderStats/presentedFrames``).
    public nonisolated final class PresentedFrames: Sendable {
        private let ledger: Ledger

        init(ledger: Ledger) {
            self.ledger = ledger
        }

        /// One frame `owner` presented and the screen showed.
        // perf-hot: 0.05us terminal-key
        public func framePresented(by owner: AnyClass) {
            #if DEBUG || CMUX_BENCH_HOOKS
            ledger.add(.contentsSets, owner: owner)
            #endif
        }
    }
}
