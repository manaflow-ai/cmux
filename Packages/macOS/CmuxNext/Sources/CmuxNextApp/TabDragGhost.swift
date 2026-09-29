import AppKit

/// Borderless floating panel with the dragged tab's image. It follows the
/// pointer across windows and outside them, and never takes focus or mouse
/// events.
final class TabDragGhost {
    private let panel: NSPanel
    private let grabOffset: CGPoint

    init(image: CGImage?, size: CGSize, grabOffset: CGPoint) {
        self.grabOffset = grabOffset
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0.92
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        if let image { imageView.image = NSImage(cgImage: image, size: size) }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = imageView
    }

    func move(to screenPoint: CGPoint) {
        panel.setFrameOrigin(CGPoint(x: screenPoint.x - grabOffset.x, y: screenPoint.y - grabOffset.y))
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func close() {
        panel.orderOut(nil)
    }
}
