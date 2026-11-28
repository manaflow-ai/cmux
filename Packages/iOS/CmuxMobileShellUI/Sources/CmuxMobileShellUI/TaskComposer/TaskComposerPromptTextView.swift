#if os(iOS)
import UIKit

/// Gives the prompt coordinator one post-layout hook to restore a user-owned
/// viewport after UIKit performs caret-visibility layout. Inherits the paste
/// interception that stages pasted images/files as task attachments.
@MainActor
final class TaskComposerPromptTextView: MobilePasteInterceptingTextView {
    var restoreManualContentOffset: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        restoreManualContentOffset?()
    }
}
#endif
