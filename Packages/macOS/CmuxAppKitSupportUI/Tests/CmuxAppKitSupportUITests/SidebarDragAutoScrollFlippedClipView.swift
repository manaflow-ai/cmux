import AppKit

@MainActor
final class SidebarDragAutoScrollFlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
