import AppKit
import CoreGraphics
import Foundation

/// Renders a captured window and forwards pane input to its owning process.
final class MacAppSurfaceView: NSView {
    private var image: NSImage?
    private var descriptor: MacAppWindowDescriptor?
    private var acceptsInput = false
    private var isMouseDown = false

    var onFocus: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    func update(
        image: NSImage?,
        descriptor: MacAppWindowDescriptor?,
        acceptsInput: Bool
    ) {
        self.image = image
        self.descriptor = descriptor
        self.acceptsInput = acceptsInput
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let image, let drawRect = imageRect(for: image) else { return }
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsInput else { return }
        onFocus?()
        window?.makeFirstResponder(self)
        isMouseDown = true
        postMouseEvent(event, type: .leftMouseDown, button: .left)
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsInput, isMouseDown else { return }
        postMouseEvent(event, type: .leftMouseDragged, button: .left)
    }

    override func mouseUp(with event: NSEvent) {
        guard acceptsInput, isMouseDown else { return }
        isMouseDown = false
        postMouseEvent(event, type: .leftMouseUp, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard acceptsInput else { return }
        onFocus?()
        window?.makeFirstResponder(self)
        postMouseEvent(event, type: .rightMouseDown, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard acceptsInput else { return }
        postMouseEvent(event, type: .rightMouseUp, button: .right)
    }

    override func scrollWheel(with event: NSEvent) {
        guard acceptsInput, let descriptor else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let scroll = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(event.scrollingDeltaY.rounded()),
            wheel2: Int32(event.scrollingDeltaX.rounded()),
            wheel3: 0
        )
        scroll?.location = targetPoint(
            for: convert(event.locationInWindow, from: nil),
            descriptor: descriptor
        )
        scroll?.postToPid(descriptor.processID)
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsInput else { return }
        onFocus?()
        event.cgEvent?.postToPid(descriptor?.processID ?? 0)
    }

    override func keyUp(with event: NSEvent) {
        guard acceptsInput else { return }
        event.cgEvent?.postToPid(descriptor?.processID ?? 0)
    }

    override func flagsChanged(with event: NSEvent) {
        guard acceptsInput else { return }
        event.cgEvent?.postToPid(descriptor?.processID ?? 0)
    }

    private func postMouseEvent(
        _ event: NSEvent,
        type: CGEventType,
        button: CGMouseButton
    ) {
        guard let descriptor else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let mouse = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: targetPoint(
                for: convert(event.locationInWindow, from: nil),
                descriptor: descriptor
            ),
            mouseButton: button
        )
        mouse?.flags = event.cgEvent?.flags ?? []
        mouse?.postToPid(descriptor.processID)
    }

    private func imageRect(for image: NSImage) -> NSRect? {
        guard let descriptor,
              let imageRepresentation = image.representations.first,
              imageRepresentation.pixelsWide > 0,
              imageRepresentation.pixelsHigh > 0 else {
            return nil
        }
        let imageSize = NSSize(
            width: CGFloat(imageRepresentation.pixelsWide),
            height: CGFloat(imageRepresentation.pixelsHigh)
        )
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        guard scale.isFinite, scale > 0 else { return nil }
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func targetPoint(
        for pointInWindow: NSPoint,
        descriptor: MacAppWindowDescriptor
    ) -> CGPoint {
        guard let image,
              let imageRect = imageRect(for: image),
              imageRect.width > 0,
              imageRect.height > 0 else {
            return CGPoint(x: descriptor.frame.midX, y: descriptor.frame.midY)
        }
        let xFraction = min(1, max(0, (pointInWindow.x - imageRect.minX) / imageRect.width))
        let yFraction = min(1, max(0, (pointInWindow.y - imageRect.minY) / imageRect.height))
        return CGPoint(
            x: descriptor.frame.minX + (xFraction * descriptor.frame.width),
            y: descriptor.frame.maxY - (yFraction * descriptor.frame.height)
        )
    }
}
