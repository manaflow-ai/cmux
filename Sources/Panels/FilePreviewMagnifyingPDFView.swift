import AppKit
import PDFKit

final class FilePreviewMagnifyingPDFView: PDFView {
    var onMagnify: ((NSEvent) -> Void)?
    var onScrollZoom: ((NSEvent) -> Void)?
    var onScroll: (() -> Void)?
    var onSmartMagnify: (() -> Void)?
    var onRotate: ((NSEvent) -> Void)?
    var onSwipe: ((NSEvent) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChanged?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChanged?(false)
        }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func magnify(with event: NSEvent) {
        if let onMagnify {
            onMagnify(event)
        } else {
            super.magnify(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if FilePreviewInteraction.hasZoomModifier(event), let onScrollZoom {
            onScrollZoom(event)
        } else {
            super.scrollWheel(with: event)
            onScroll?()
        }
    }

    override func smartMagnify(with event: NSEvent) {
        if let onSmartMagnify {
            onSmartMagnify()
        } else {
            super.smartMagnify(with: event)
        }
    }

    override func rotate(with event: NSEvent) {
        if let onRotate {
            onRotate(event)
        } else {
            super.rotate(with: event)
        }
    }

    override func swipe(with event: NSEvent) {
        if let onSwipe {
            onSwipe(event)
        } else {
            super.swipe(with: event)
        }
    }
}
