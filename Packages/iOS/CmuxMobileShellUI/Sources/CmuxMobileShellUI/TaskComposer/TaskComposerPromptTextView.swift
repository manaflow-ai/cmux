#if os(iOS)
import UIKit

/// Gives the prompt coordinator one post-layout hook to restore a user-owned
/// viewport after UIKit performs caret-visibility layout.
@MainActor
final class TaskComposerPromptTextView: UITextView {
    var restoreManualContentOffset: (() -> Void)?
    /// Returns `true` when the composer consumed a non-text pasteboard payload
    /// as an attachment. Plain text stays on UIKit's native paste path.
    var pasteAttachment: (() -> Bool)?

    override func layoutSubviews() {
        super.layoutSubviews()
        restoreManualContentOffset?()
    }

    override func paste(_ sender: Any?) {
        guard pasteAttachment?() != true else { return }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let pasteboard = UIPasteboard.general
            if pasteboard.hasImages || (pasteboard.urls ?? []).contains(where: \.isFileURL) {
                return true
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
#endif
