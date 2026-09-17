#if os(iOS)
import QuickLook
import SwiftUI

/// Hosts Quick Look over one on-disk file without copying or re-encoding it.
/// Shared by the task composer's attachment preview and the terminal
/// composer's chip preview so both surfaces present staged attachments the
/// same way.
struct MobileAttachmentQuickLookView: UIViewControllerRepresentable {
    let fileURL: URL
    let title: String
    var accessibilityIdentifier = "MobileAttachmentQuickLook"

    func makeCoordinator() -> MobileAttachmentQuickLookCoordinator {
        MobileAttachmentQuickLookCoordinator(
            item: MobileAttachmentQuickLookItem(
                fileURL: fileURL,
                title: title
            )
        )
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.view.accessibilityIdentifier = accessibilityIdentifier
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
final class MobileAttachmentQuickLookCoordinator:
    NSObject,
    QLPreviewControllerDataSource
{
    private var item: MobileAttachmentQuickLookItem

    init(item: MobileAttachmentQuickLookItem) {
        self.item = item
    }

    func update(fileURL: URL, title: String) -> Bool {
        guard item.fileURL != fileURL || item.title != title else { return false }
        item = MobileAttachmentQuickLookItem(
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

/// Supplies the staged URL and user-visible name to Quick Look.
final class MobileAttachmentQuickLookItem: NSObject, QLPreviewItem {
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
