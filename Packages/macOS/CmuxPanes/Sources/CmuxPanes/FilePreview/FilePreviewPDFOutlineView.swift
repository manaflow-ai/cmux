public import AppKit

/// The `NSOutlineView` subclass backing the PDF table-of-contents sidebar.
///
/// Reports focus gain/loss through ``onFocusChanged`` and takes first responder
/// on mouse-down so a click into the outline focuses it. The owning container
/// supplies the outline data source / delegate.
public final class FilePreviewPDFOutlineView: NSOutlineView {
    /// Called when the outline gains (`true`) or loses (`false`) focus.
    public var onFocusChanged: ((Bool) -> Void)?

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
        super.mouseDown(with: event)
    }
}
