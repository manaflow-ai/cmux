#if os(iOS)
import UIKit

/// Gives the prompt coordinator one post-layout hook to restore a user-owned
/// viewport after UIKit performs caret-visibility layout.
@MainActor
final class TaskComposerPromptTextView: UITextView {
    var restoreManualContentOffset: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        restoreManualContentOffset?()
    }
}
#endif
