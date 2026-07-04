import AppKit

@MainActor
final class PassthroughWindowOverlayContainerView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
