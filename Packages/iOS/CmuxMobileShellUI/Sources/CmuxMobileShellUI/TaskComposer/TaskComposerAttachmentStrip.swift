#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxAgentChatUI
import SwiftUI
import UIKit

/// Shared horizontal strip of staged New Task attachments.
struct TaskComposerAttachmentStrip: View {
    let attachments: [TaskComposerAttachment]
    let isDisabled: Bool
    let isPreparing: Bool
    let onPreviewDismiss: () -> Void
    let remove: (UUID) -> Void

    init(
        attachments: [TaskComposerAttachment],
        isDisabled: Bool,
        isPreparing: Bool = false,
        onPreviewDismiss: @escaping () -> Void = {},
        remove: @escaping (UUID) -> Void
    ) {
        self.attachments = attachments
        self.isDisabled = isDisabled
        self.isPreparing = isPreparing
        self.onPreviewDismiss = onPreviewDismiss
        self.remove = remove
    }

    var body: some View {
        MobileAttachmentCardStrip(
            attachments: attachments,
            isDisabled: isDisabled,
            isPreparing: isPreparing,
            onPreviewDismiss: onPreviewDismiss,
            remove: remove
        )
    }
}
#endif
