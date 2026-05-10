import AppKit
import SwiftUI

struct InteractiveWindowPreview: NSViewRepresentable {
    let image: CGImage?
    let window: HostWindow
    let onMouse: (WindowMouseInput) -> Void
    let onScroll: (WindowScrollInput) -> Void
    let onKey: (WindowKeyInput) -> Void

    func makeNSView(context: Context) -> InteractiveWindowPreviewView {
        let view = InteractiveWindowPreviewView()
        view.onMouse = onMouse
        view.onScroll = onScroll
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: InteractiveWindowPreviewView, context: Context) {
        nsView.image = image
        nsView.targetWindow = window
        nsView.onMouse = onMouse
        nsView.onScroll = onScroll
        nsView.onKey = onKey
    }
}

final class InteractiveWindowPreviewView: NSView {
    private var mouseTrackingArea: NSTrackingArea?

    var image: CGImage? {
        didSet {
            layer?.contents = image
            needsDisplay = true
        }
    }

    var targetWindow: HostWindow?
    var onMouse: ((WindowMouseInput) -> Void)?
    var onScroll: ((WindowScrollInput) -> Void)?
    var onKey: ((WindowKeyInput) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        emitMouse(event, phase: .moved, button: .left)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emitMouse(event, phase: .down, button: .left)
    }

    override func mouseDragged(with event: NSEvent) {
        emitMouse(event, phase: .dragged, button: .left)
    }

    override func mouseUp(with event: NSEvent) {
        emitMouse(event, phase: .up, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emitMouse(event, phase: .down, button: .right)
    }

    override func rightMouseDragged(with event: NSEvent) {
        emitMouse(event, phase: .dragged, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        emitMouse(event, phase: .up, button: .right)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emitMouse(event, phase: .down, button: .other(event.buttonNumber))
    }

    override func otherMouseDragged(with event: NSEvent) {
        emitMouse(event, phase: .dragged, button: .other(event.buttonNumber))
    }

    override func otherMouseUp(with event: NSEvent) {
        emitMouse(event, phase: .up, button: .other(event.buttonNumber))
    }

    override func mouseMoved(with event: NSEvent) {
        emitMouse(event, phase: .moved, button: .left)
    }

    override func scrollWheel(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let normalizedPoint = normalizedPoint(for: event) else {
            return
        }

        onScroll?(
            WindowScrollInput(
                normalizedPoint: normalizedPoint,
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY
            )
        )
    }

    override func keyDown(with event: NSEvent) {
        emitKey(event, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        emitKey(event, isDown: false)
    }

    private func emitMouse(_ event: NSEvent, phase: WindowMousePhase, button: WindowMouseButton) {
        guard let normalizedPoint = normalizedPoint(for: event) else {
            return
        }

        onMouse?(
            WindowMouseInput(
                phase: phase,
                button: button,
                normalizedPoint: normalizedPoint,
                clickCount: event.clickCount
            )
        )
    }

    private func emitKey(_ event: NSEvent, isDown: Bool) {
        onKey?(
            WindowKeyInput(
                keyCode: UInt16(event.keyCode),
                characters: event.characters,
                modifierFlags: event.modifierFlags,
                isDown: isDown,
                isRepeat: event.isARepeat
            )
        )
    }

    private func normalizedPoint(for event: NSEvent) -> CGPoint? {
        let localPoint = convert(event.locationInWindow, from: nil)
        let contentRect = imageContentRect()
        guard contentRect.contains(localPoint), contentRect.width > 0, contentRect.height > 0 else {
            return nil
        }

        return CGPoint(
            x: (localPoint.x - contentRect.minX) / contentRect.width,
            y: (localPoint.y - contentRect.minY) / contentRect.height
        )
    }

    private func imageContentRect() -> CGRect {
        guard let image else {
            return bounds
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}
