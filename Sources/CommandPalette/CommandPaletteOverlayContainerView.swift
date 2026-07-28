import AppKit

@MainActor
final class CommandPaletteOverlayContainerView: NSView {
    var capturesMouseEvents = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard capturesMouseEvents else { return nil }
        return super.hitTest(point)
    }
}
