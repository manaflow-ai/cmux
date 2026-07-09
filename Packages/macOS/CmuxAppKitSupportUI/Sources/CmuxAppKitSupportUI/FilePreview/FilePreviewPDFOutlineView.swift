public import AppKit

/// `NSOutlineView` subclass for the file-preview PDF outline sidebar that reports
/// first-responder gain/loss to its container.
///
/// First-responder status changes are forwarded through ``onFocusChanged`` (`true`
/// on gain, `false` on loss); a mouse-down makes the view first responder before
/// the default handling runs.
public final class FilePreviewPDFOutlineView: NSOutlineView {
    /// Invoked when first-responder status is gained (`true`) or lost (`false`).
    public var onFocusChanged: ((Bool) -> Void)?

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
        super.mouseDown(with: event)
    }
}
