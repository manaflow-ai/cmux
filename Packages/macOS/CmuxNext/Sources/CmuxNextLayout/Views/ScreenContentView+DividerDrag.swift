import AppKit
import CmuxNextInput

/// Divider and column-edge drags, emitted as transactional layout intents (`DividerDrag`).
extension ScreenContentView {
    func handleDrag(kind: DividerHandleView.Kind, event: DividerHandleView.DragEvent) {
        DividerDrag(screen: self).handle(kind: kind, event: event)
    }

    /// Ends a drag whose handle left the tree: no release will come. It is
    /// cancelled (`LayoutModel.cancelGesture`) and gesture mode ends.
    func endDrag() { DividerDrag(screen: self).cancel() }

    /// A new handle's drags read this screen's frame-aligned input (``LayoutRootView/dragFrameInput``)
    /// and resampler (``LayoutRootView/dragResampler``), the latest each time a drag begins.
    func followDragInput(_ handle: DividerHandleView) {
        handle.pointerFrames = { [weak self] in self?.context.dragFrameInput }
        handle.dragResampler = { [weak self] in self?.newDragResampler() }
    }

    /// A new divider drag's resampler; none under Reduce Motion, where the divider follows the real
    /// pointer.
    func newDragResampler() -> DragResampler? {
        context.newDragResampler()
    }
}
