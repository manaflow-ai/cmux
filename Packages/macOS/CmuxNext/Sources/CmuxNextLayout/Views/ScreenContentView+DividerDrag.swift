import AppKit

/// Divider and column-edge drags, emitted as transactional layout intents (`DividerDrag`).
extension ScreenContentView {
    func handleDrag(kind: DividerHandleView.Kind, event: DividerHandleView.DragEvent) {
        DividerDrag(screen: self).handle(kind: kind, event: event)
    }

    /// Ends a drag whose handle left the tree: no release will come. It is
    /// cancelled (`LayoutModel.cancelGesture`) and gesture mode ends.
    func endDrag() { DividerDrag(screen: self).cancel() }

    /// A display frame began: a divider move that waited in the last frame applies now, at the
    /// drag's latest pointer and keys. Returns true when one did, so the root lays this frame out
    /// from the model at once instead of on the observation's next turn.
    func applyPendingDividerMove() -> Bool {
        dividerMovedInFrame = false
        guard dividerMovePending, let drag = activeDrag else {
            dividerMovePending = false
            return false
        }
        DividerDrag(screen: self).apply(at: drag.lastWindowPoint, phase: .changed)
        return true
    }
}
