public import AppKit
import CmuxFoundation

/// `NSCollectionView` subclass for the file-preview PDF thumbnail strip that
/// reports focus, primary clicks, and arrow/page-key navigation to its container.
///
/// First-responder gain/loss is forwarded through ``onFocusChanged``; a primary
/// click on an item forwards that item's index through ``onPrimaryClickItem``;
/// up/down and page-up/page-down keys are routed through
/// ``FilePreviewPDFKeyboardRouting`` and surface a page delta on
/// ``onPageNavigation`` when they map to a navigation action.
public final class FilePreviewPDFThumbnailCollectionView: NSCollectionView {
    private let keyboardRouting = FilePreviewPDFKeyboardRouting()

    /// Invoked when first-responder status is gained (`true`) or lost (`false`).
    public var onFocusChanged: ((Bool) -> Void)?
    /// Invoked with a signed page delta when an arrow/page key requests navigation.
    public var onPageNavigation: ((Int) -> Void)?
    /// Invoked with the item index of a primary (left-button) click.
    public var onPrimaryClickItem: ((Int) -> Void)?

    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }

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
        if event.buttonNumber == 0 {
            let location = convert(event.locationInWindow, from: nil)
            if let indexPath = indexPathForItem(at: location) {
                onPrimaryClickItem?(indexPath.item)
                return
            }
        }
        super.mouseDown(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        if handlePageNavigation(event) {
            return
        }
        super.keyDown(with: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePageNavigation(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handlePageNavigation(_ event: NSEvent) -> Bool {
        guard case .navigatePage(let delta) = keyboardRouting.action(
            for: event,
            region: .pdfThumbnails
        ), let onPageNavigation else {
            return false
        }
        onPageNavigation(delta)
        return true
    }
}
