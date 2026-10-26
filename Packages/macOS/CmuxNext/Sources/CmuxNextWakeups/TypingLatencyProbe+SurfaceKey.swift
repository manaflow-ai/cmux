import CmuxNextCompat

extension TypingLatencyProbe {
    /// Names one terminal session's surfaces to the probe. The key router opens a press on it
    /// (``TypingLatencyProbe/keyReachedTerminal(_:display:)``), Ghostty's write callback takes that surface's
    /// oldest unwritten press (``TypingLatencyProbe/inputWritten(on:)``), and the surface's output lane
    /// and frame mark by it. A plain value (``TypingLatencyProbe/makeSurfaceKey()``): a surface pays no
    /// allocation for the probe, and the presses it names live in the probe's own table, so they are
    /// bounded by ``TypingLatencyProbe/openCapacity`` like every other press.
    public struct SurfaceKey: Sendable, Hashable {
        let id: UInt64

        /// The number trace records name the surface by (`ghostty.render` and `frame.gpu_done` arg0): unique in
        /// this probe, never 0.
        public var traceID: UInt64 { id }
    }

    /// A key that no other surface of this probe has.
    public func makeSurfaceKey() -> SurfaceKey {
        SurfaceKey(id: surfaceIDs.wrappingAdd(1, ordering: .relaxed).newValue)
    }
}
