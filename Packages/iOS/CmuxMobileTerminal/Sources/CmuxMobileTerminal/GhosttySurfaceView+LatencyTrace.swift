#if DEBUG && canImport(UIKit)
extension GhosttySurfaceView {
    /// Associates subsequent render completions with the latest applied frame.
    ///
    /// - Parameter sequence: Applied terminal byte high-water mark.
    public func markLatencyAppliedSequence(_ sequence: UInt64) {
        latencyLastAppliedSequence = sequence
    }
}
#endif
