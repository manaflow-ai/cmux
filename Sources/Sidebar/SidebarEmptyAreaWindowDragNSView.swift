import AppKit

/// Backing view for the empty region below the workspace list.
///
/// Presses that turn into drags move the window; presses that do not fall
/// through to normal handling untouched.
@MainActor
final class SidebarEmptyAreaWindowDragNSView: NSView {
    private let windowDragController = SidebarEmptyAreaWindowDragController()

    /// Routes single presses through threshold-based window dragging.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else {
            super.mouseDown(with: event)
            return
        }
        if windowDragController.perform(with: event, in: self) { return }
        super.mouseDown(with: event)
    }
}
