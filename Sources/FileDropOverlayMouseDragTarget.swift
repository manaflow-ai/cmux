import AppKit

/// Weakly captures one AppKit view for the lifetime of a forwarded drag.
final class FileDropOverlayMouseDragTarget {
    weak var view: NSView?

    init(view: NSView) {
        self.view = view
    }
}
