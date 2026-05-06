import AppKit
import Carbon.HIToolbox
import PDFKit

final class FilePreviewMagnifyingPDFView: PDFView {
    private static let keyboardScrollStep: CGFloat = 48

    var onMagnify: ((NSEvent) -> Void)?
    var onScrollZoom: ((NSEvent) -> Void)?
    var onScroll: (() -> Void)?
    var onSmartMagnify: (() -> Void)?
    var onRotate: ((NSEvent) -> Void)?
    var onSwipe: ((NSEvent) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

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

    override func keyDown(with event: NSEvent) {
        if handleKeyboardScroll(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyboardScroll(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
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

    private func handleKeyboardScroll(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let visualDirection = keyboardScrollDirection(for: event) else {
            return false
        }
        return scrollVerticallyByKeyboardStep(visualDirection: visualDirection)
    }

    private func keyboardScrollDirection(for event: NSEvent) -> CGFloat? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option, .shift]).isEmpty else {
            return nil
        }
        switch Int(event.keyCode) {
        case kVK_UpArrow:
            return -1
        case kVK_DownArrow:
            return 1
        default:
            return nil
        }
    }

    private func scrollVerticallyByKeyboardStep(visualDirection: CGFloat) -> Bool {
        guard let scrollView = pdfScrollView(),
              let documentView = scrollView.documentView else {
            return false
        }
        let clipView = scrollView.contentView
        let yDelta = (clipView.isFlipped ? 1 : -1) * visualDirection * Self.keyboardScrollStep
        let nextOrigin = FilePreviewViewport.clampedClipOrigin(
            documentPoint: CGPoint(
                x: clipView.bounds.origin.x,
                y: clipView.bounds.origin.y + yDelta
            ),
            anchorOffsetInClip: .zero,
            documentBounds: documentView.bounds,
            clipSize: clipView.bounds.size
        )
        clipView.scroll(to: nextOrigin)
        scrollView.reflectScrolledClipView(clipView)
        onScroll?()
        return true
    }

    private func pdfScrollView() -> NSScrollView? {
        firstScrollView(in: self)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }
}
