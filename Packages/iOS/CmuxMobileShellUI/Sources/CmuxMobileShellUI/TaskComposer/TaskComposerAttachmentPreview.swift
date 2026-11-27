#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Presents the exact staged attachment through the system document preview.
struct TaskComposerAttachmentPreview: View {
    @Environment(\.dismiss) private var dismiss

    let attachment: TaskComposerAttachment

    var body: some View {
        NavigationStack {
            MobileAttachmentQuickLookView(
                fileURL: attachment.localStagedFileURL,
                title: attachment.displayName,
                accessibilityIdentifier: "MobileTaskComposerAttachmentQuickLook"
            )
            .navigationTitle(attachment.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string(
                        "mobile.common.done",
                        defaultValue: "Done"
                    )) {
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("MobileTaskComposerAttachmentPreview")
    }
}
#endif
