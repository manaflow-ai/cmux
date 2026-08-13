#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import QuickLook
import SwiftUI

/// Presents the exact staged attachment through the system document preview.
struct TaskComposerAttachmentPreview: View {
    @Environment(\.dismiss) private var dismiss

    let attachment: TaskComposerAttachment

    var body: some View {
        NavigationStack {
            TaskComposerAttachmentQuickLookView(
                fileURL: attachment.localStagedFileURL,
                title: attachment.displayName
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

/// Hosts Quick Look without copying or re-encoding the staged file.
private struct TaskComposerAttachmentQuickLookView: UIViewControllerRepresentable {
    let fileURL: URL
    let title: String

    func makeCoordinator() -> TaskComposerAttachmentQuickLookCoordinator {
        TaskComposerAttachmentQuickLookCoordinator(
            item: TaskComposerAttachmentQuickLookItem(
                fileURL: fileURL,
                title: title
            )
        )
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.view.accessibilityIdentifier =
            "MobileTaskComposerAttachmentQuickLook"
        return controller
    }

    func updateUIViewController(
        _ controller: QLPreviewController,
        context: Context
    ) {
        let didChange = context.coordinator.update(
            fileURL: fileURL,
            title: title
        )
        if didChange {
            controller.reloadData()
        }
    }
}

/// Retains the item object for Quick Look's data-source lifetime.
@MainActor
private final class TaskComposerAttachmentQuickLookCoordinator:
    NSObject,
    QLPreviewControllerDataSource
{
    private var item: TaskComposerAttachmentQuickLookItem

    init(item: TaskComposerAttachmentQuickLookItem) {
        self.item = item
    }

    func update(fileURL: URL, title: String) -> Bool {
        guard item.fileURL != fileURL || item.title != title else { return false }
        item = TaskComposerAttachmentQuickLookItem(
            fileURL: fileURL,
            title: title
        )
        return true
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        1
    }

    func previewController(
        _ controller: QLPreviewController,
        previewItemAt index: Int
    ) -> any QLPreviewItem {
        item
    }
}

/// Supplies the staged URL and original user-visible name to Quick Look.
private final class TaskComposerAttachmentQuickLookItem: NSObject, QLPreviewItem {
    let fileURL: URL
    let title: String

    var previewItemURL: URL? { fileURL }
    var previewItemTitle: String? { title }

    init(fileURL: URL, title: String) {
        self.fileURL = fileURL
        self.title = title
    }
}
#endif
