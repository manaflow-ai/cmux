import AppKit

/// Divider and column-edge drags, emitted as transactional layout intents (`DividerDrag`).
extension ScreenContentView {
    func handleDrag(kind: DividerHandleView.Kind, event: DividerHandleView.DragEvent) {
        DividerDrag(screen: self).handle(kind: kind, event: event)
    }

    /// Ends a drag whose handle left the tree: no release will come. It is
    /// cancelled (`LayoutModel.cancelGesture`) and gesture mode ends.
    func endDrag() { DividerDrag(screen: self).cancel() }
}
