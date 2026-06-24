public import AppKit
public import SwiftUI

/// Transparent AppKit overlay that sits over the omnibar pill, providing an
/// I-beam cursor and forwarding pointer events to the live native omnibar field
/// resolved from the injected ``BrowserOmnibarNativeFieldRegistry``.
///
/// The registry is injected (no process-wide singleton); the same instance the
/// browser-panel view passes to ``OmnibarTextFieldRepresentable`` is shared here
/// so both surfaces resolve the same field.
@MainActor
public final class BrowserOmnibarInteractionView: NSView {
    public var panelId: UUID?
    public var nativeFieldRegistry: BrowserOmnibarNativeFieldRegistry?
    private var trackingArea: NSTrackingArea?

    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    public override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .inVisibleRect,
            .activeAlways,
            .cursorUpdate,
            .mouseMoved,
            .mouseEnteredAndExited,
            .enabledDuringMouseDrag,
        ]
        let next = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        guard nativeFieldRegistry?.field(for: panelId, in: window) != nil else {
            return nil
        }
        return self
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override func cursorUpdate(with event: NSEvent) {
        setIBeamCursor()
    }

    public override func mouseEntered(with event: NSEvent) {
        setIBeamCursor()
    }

    public override func mouseMoved(with event: NSEvent) {
        setIBeamCursor()
    }

    public override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    public override func mouseDown(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.mouseDown(with: event)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.mouseDragged(with: event)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.mouseUp(with: event)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.rightMouseDown(with: event)
        }
    }

    public override func rightMouseDragged(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.rightMouseDragged(with: event)
        }
    }

    public override func rightMouseUp(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.rightMouseUp(with: event)
        }
    }

    public override func otherMouseDown(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.otherMouseDown(with: event)
        }
    }

    public override func otherMouseDragged(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.otherMouseDragged(with: event)
        }
    }

    public override func otherMouseUp(with event: NSEvent) {
        forwardMouseEvent(event) { field, event in
            field.otherMouseUp(with: event)
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    private func setIBeamCursor() {
        NSCursor.iBeam.set()
    }

    private func forwardMouseEvent(
        _ event: NSEvent,
        _ apply: (OmnibarNativeTextField, NSEvent) -> Void
    ) {
        guard let field = nativeFieldRegistry?.field(for: panelId, in: window) else {
            return
        }
        apply(field, event)
    }
}
