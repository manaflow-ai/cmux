import AppKit

final class FilePreviewPDFThumbnailCollectionView: NSCollectionView {
    var onFocusChanged: ((Bool) -> Void)?
    var onPageNavigation: ((Int) -> Void)?
    var onPrimaryClickItem: ((Int) -> Void)?

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
        if event.buttonNumber == 0 {
            let location = convert(event.locationInWindow, from: nil)
            if let indexPath = indexPathForItem(at: location) {
                onPrimaryClickItem?(indexPath.item)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handlePageNavigation(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePageNavigation(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handlePageNavigation(_ event: NSEvent) -> Bool {
        guard ownsKeyboardFocus else { return false }
        guard case .navigatePage(let delta) = FilePreviewPDFKeyboardRouting.action(
            for: event,
            region: .pdfThumbnails
        ), let onPageNavigation else {
            return false
        }
        onPageNavigation(delta)
        return true
    }

    private var ownsKeyboardFocus: Bool {
        guard let firstResponder = window?.firstResponder else { return false }
        if firstResponder === self { return true }
        guard let view = firstResponder as? NSView else { return false }
        return view.isDescendant(of: self)
    }
}
