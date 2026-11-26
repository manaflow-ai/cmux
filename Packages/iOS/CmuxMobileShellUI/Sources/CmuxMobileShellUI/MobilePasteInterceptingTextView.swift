#if os(iOS)
import UIKit

/// A `UITextView` whose system Paste action routes image and file pasteboard
/// content to the hosting composer (which stages it as attachments) while
/// plain text keeps native paste behavior. Both composer prompt editors
/// subclass this so every paste entry point — edit menu, hardware Cmd+V,
/// keyboard paste key — shares one interception path.
@MainActor
class MobilePasteInterceptingTextView: UITextView {
    /// Stages the pasteboard's attachment content; returns `true` when the
    /// paste was consumed (so native text insertion must not also run).
    var pasteAttachments: (() -> Bool)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Advertise Paste for image/file content the native text view would
        // refuse. The probe reads only pasteboard metadata, so the paste
        // privacy prompt cannot fire from menu construction.
        if action == #selector(paste(_:)),
           isEditable,
           pasteAttachments != nil,
           MobilePasteboardReader().hasAttachmentContent(in: .general) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if pasteAttachments?() == true { return }
        super.paste(sender)
    }
}
#endif
