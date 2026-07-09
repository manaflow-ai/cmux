public import AppKit
public import PDFKit

/// `PDFView` subclass for the file-preview PDF canvas that forwards trackpad and
/// scroll gestures to the owning container instead of applying them itself.
///
/// Pinch-magnify, modifier-armed scroll-to-zoom (via ``FilePreviewZoomInteraction``),
/// smart-magnify, rotate, and swipe each call an optional closure the container
/// installs; when a closure is absent the gesture falls back to the standard
/// `PDFView` behavior. Focus changes and plain scrolls are reported through their
/// own callbacks so the container can track first-responder state and viewport drift.
public final class FilePreviewMagnifyingPDFView: PDFView {
    /// Invoked on a pinch-magnify gesture; falls back to `super` when unset.
    public var onMagnify: ((NSEvent) -> Void)?
    /// Invoked on a modifier-armed scroll-to-zoom gesture; falls back to `super` when unset.
    public var onScrollZoom: ((NSEvent) -> Void)?
    /// Invoked after a plain scroll wheel event passes through to `super`.
    public var onScroll: (() -> Void)?
    /// Invoked on a double-tap smart-magnify gesture; falls back to `super` when unset.
    public var onSmartMagnify: (() -> Void)?
    /// Invoked on a two-finger rotate gesture; falls back to `super` when unset.
    public var onRotate: ((NSEvent) -> Void)?
    /// Invoked on a swipe gesture; falls back to `super` when unset.
    public var onSwipe: ((NSEvent) -> Void)?
    /// Invoked when first-responder status is gained (`true`) or lost (`false`).
    public var onFocusChanged: ((Bool) -> Void)?

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChanged?(true)
        }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChanged?(false)
        }
        return resigned
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

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
            onScroll?()
        }
    }

    public override func smartMagnify(with event: NSEvent) {
        if let onSmartMagnify {
            onSmartMagnify()
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

    public override func swipe(with event: NSEvent) {
        if let onSwipe {
            onSwipe(event)
        } else {
            super.swipe(with: event)
        }
    }
}
