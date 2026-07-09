public import AppKit

/// Scrolling, pannable container for the file-preview image canvas.
///
/// Hosts the zoomed image document view and translates raw trackpad/mouse gestures into the
/// preview's zoom and pan behavior: pinch magnify, modifier-armed scroll-to-zoom (via
/// ``FilePreviewZoomInteraction``), double-tap smart magnify, two-finger rotate, and
/// click-drag panning with an open/closed-hand cursor. Each gesture forwards to an optional
/// callback the owning container installs; when a callback is absent the gesture falls back to
/// the standard `NSScrollView` behavior.
public final class FilePreviewImageScrollView: NSScrollView {
    /// Invoked on a pinch-magnify gesture; falls back to `super` when unset.
    public var onMagnify: ((NSEvent) -> Void)?
    /// Invoked on a modifier-armed scroll-to-zoom gesture; falls back to `super` when unset.
    public var onScrollZoom: ((NSEvent) -> Void)?
    /// Invoked on a double-tap smart-magnify gesture; falls back to `super` when unset.
    public var onSmartMagnify: ((NSEvent) -> Void)?
    /// Invoked on a two-finger rotate gesture; falls back to `super` when unset.
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
        if FilePreviewZoomInteraction.standard.hasZoomModifier(event), let onScrollZoom {
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
