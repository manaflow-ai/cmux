import AppKit

@MainActor
final class SidebarDragAutoScrollFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
