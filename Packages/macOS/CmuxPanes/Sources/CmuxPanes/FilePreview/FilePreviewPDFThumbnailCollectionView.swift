public import AppKit

/// The `NSCollectionView` subclass backing the PDF thumbnail sidebar.
///
/// Adds first-responder focus reporting, primary-click hit testing, and
/// unmodified arrow / page-key page navigation (resolved through
/// ``FilePreviewPDFKeyboardAction``). All behavior is surfaced to the owning
/// sidebar view via closure callbacks rather than a delegate.
public final class FilePreviewPDFThumbnailCollectionView: NSCollectionView {
    /// Called when the collection view gains (`true`) or loses (`false`) focus.
    public var onFocusChanged: ((Bool) -> Void)?
    /// Called with a signed page delta when an arrow / page key navigates.
    public var onPageNavigation: ((Int) -> Void)?
    /// Called with the item index when a primary (left) click hits an item.
    public var onPrimaryClickItem: ((Int) -> Void)?

    override public var acceptsFirstResponder: Bool { true }
    override public var canBecomeKeyView: Bool { true }

    override public func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChanged?(true)
        }
        return accepted
    }

    override public func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChanged?(false)
        }
        return resigned
    }

    override public func mouseDown(with event: NSEvent) {
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

    override public func keyDown(with event: NSEvent) {
        if handlePageNavigation(event) {
            return
        }
        super.keyDown(with: event)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePageNavigation(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handlePageNavigation(_ event: NSEvent) -> Bool {
        guard case .navigatePage(let delta) = FilePreviewPDFKeyboardAction.action(
            for: event,
            region: .pdfThumbnails
        ), let onPageNavigation else {
            return false
        }
        onPageNavigation(delta)
        return true
    }
}
