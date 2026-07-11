/// Geometry work that must enter the surface FIFO immediately before output.
extension GhosttySurfaceView {
    /// Enqueues any required geometry immediately before a nonempty output
    /// chunk. The caller queues `processOutputAndWait` in the same main-actor
    /// turn, so no optimistic local scroll can enter the surface FIFO between
    /// the resize and the authoritative repaint.
    public func prepareViewSizeForOrderedOutput(cols: Int, rows: Int) {
        let changed = updateEffectiveGrid(cols: cols, rows: rows, confirmedViewportEcho: false)
        enqueueGeometryForOrderedOutputIfNeeded(changed: changed)
    }
}
