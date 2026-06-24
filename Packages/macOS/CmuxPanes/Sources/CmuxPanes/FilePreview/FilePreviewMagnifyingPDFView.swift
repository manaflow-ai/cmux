public import AppKit
public import PDFKit

/// A `PDFView` subclass that forwards magnify / modifier-scroll-zoom / scroll /
/// smart-magnify / rotate / swipe gestures and first-responder focus changes to
/// closures the file-preview PDF container installs, falling back to the native
/// `PDFView` behavior when a closure is absent.
public final class FilePreviewMagnifyingPDFView: PDFView {
    /// Called for a pinch-magnify gesture (the container converts it to a scale
    /// factor).
    public var onMagnify: ((NSEvent) -> Void)?
    /// Called for a modifier-held scroll-wheel zoom gesture.
    public var onScrollZoom: ((NSEvent) -> Void)?
    /// Called after a non-zoom scroll so the container can refresh page controls.
    public var onScroll: (() -> Void)?
    /// Called for a trackpad smart-magnify (double-tap) gesture.
    public var onSmartMagnify: (() -> Void)?
    /// Called for a two-finger rotate gesture.
    public var onRotate: ((NSEvent) -> Void)?
    /// Called for a two-finger swipe gesture (the container navigates pages).
    public var onSwipe: ((NSEvent) -> Void)?
    /// Called when the view gains (`true`) or loses (`false`) first-responder.
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
        if event.filePreviewHasZoomModifier, let onScrollZoom {
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
