/// Identifies the mouse button whose AppKit drag target is captured.
enum FileDropOverlayMouseDragButton: Hashable {
    case left
    case right
    case other(Int)
}
