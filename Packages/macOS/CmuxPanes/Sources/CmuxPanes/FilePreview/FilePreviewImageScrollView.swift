public import AppKit

/// `NSScrollView` for the file preview that forwards zoom/rotate gestures to
/// closures and implements click-drag panning of the document view.
///
/// Magnify, modifier-scroll-zoom, smart-magnify, and rotate events are handed
/// to the owner via the `on*` closures when set. A double click triggers
/// `onSmartMagnify`; a single drag pans the document (closed-hand cursor while
/// dragging, open-hand cursor at rest), clamped so the document origin stays
/// within the scrollable range.
public final class FilePreviewImageScrollView: NSScrollView {
    /// Invoked for a pinch magnify gesture; falls back to AppKit when nil.
    public var onMagnify: ((NSEvent) -> Void)?
    /// Invoked for a modifier-held scroll-to-zoom; falls back to AppKit when nil.
    public var onScrollZoom: ((NSEvent) -> Void)?
    /// Invoked for a smart-magnify (double-tap or double-click) gesture; falls back to AppKit when nil.
    public var onSmartMagnify: ((NSEvent) -> Void)?
    /// Invoked for a rotate gesture; falls back to AppKit when nil.
    public var onRotate: ((NSEvent) -> Void)?
    private var panStartClipPoint: CGPoint?
    private var panStartDocumentOrigin: CGPoint?
    private var hasPushedPanCursor = false

    public override var acceptsFirstResponder: Bool { true }

    public override func magnify(with event: NSEvent) {
        if let onMagnify {
            onMagnify(event)
        } else {
            super.magnify(with: event)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.filePreviewHasZoomModifier, let onScrollZoom {
            onScrollZoom(event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    public override func smartMagnify(with event: NSEvent) {
        if let onSmartMagnify {
            onSmartMagnify(event)
        } else {
            super.smartMagnify(with: event)
        }
    }

    public override func rotate(with event: NSEvent) {
        if let onRotate {
            onRotate(event)
        } else {
            super.rotate(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2, let onSmartMagnify {
            onSmartMagnify(event)
            return
        }
        panStartClipPoint = contentView.convert(event.locationInWindow, from: nil)
        panStartDocumentOrigin = contentView.bounds.origin
        NSCursor.closedHand.push()
        hasPushedPanCursor = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let panStartClipPoint, let panStartDocumentOrigin else {
            super.mouseDragged(with: event)
            return
        }
        let currentClipPoint = contentView.convert(event.locationInWindow, from: nil)
        let delta = CGPoint(
            x: currentClipPoint.x - panStartClipPoint.x,
            y: currentClipPoint.y - panStartClipPoint.y
        )
        scroll(toDocumentOrigin: CGPoint(
            x: panStartDocumentOrigin.x - delta.x,
            y: panStartDocumentOrigin.y - delta.y
        ))
    }

    public override func mouseUp(with event: NSEvent) {
        endPan()
    }

    public override func mouseExited(with event: NSEvent) {
        endPan()
        super.mouseExited(with: event)
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    private func scroll(toDocumentOrigin origin: CGPoint) {
        guard let documentView else { return }
        let clipSize = contentView.bounds.size
        let documentSize = documentView.bounds.size
        let maxOrigin = CGPoint(
            x: max(0, documentSize.width - clipSize.width),
            y: max(0, documentSize.height - clipSize.height)
        )
        let nextOrigin = CGPoint(
            x: min(max(0, origin.x), maxOrigin.x),
            y: min(max(0, origin.y), maxOrigin.y)
        )
        contentView.scroll(to: nextOrigin)
        reflectScrolledClipView(contentView)
    }

    private func endPan() {
        panStartClipPoint = nil
        panStartDocumentOrigin = nil
        if hasPushedPanCursor {
            NSCursor.pop()
            hasPushedPanCursor = false
        }
    }
}
