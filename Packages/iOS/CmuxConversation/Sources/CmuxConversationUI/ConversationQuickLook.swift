#if canImport(UIKit) && canImport(QuickLook)
import CmuxConversationCore
import QuickLook
import UIKit

/// One attachment as Quick Look sees it: a local copy and the title Messages
/// shows ("Photo" for a photo, the file name for a document).
final class ConversationQuickLookItem: NSObject, QLPreviewItem, Sendable {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}

/// Messages opens attachments (photos and documents alike) in Quick Look:
/// the preview zooms out of the bubble, swipes down to close, and carries
/// the share button. This presents one attachment from its bubble view.
@MainActor
final class ConversationQuickLookPresenter: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    private let item: ConversationQuickLookItem
    private weak var sourceView: UIView?
    /// Called when the preview has closed (the bubble shows again).
    var onDismiss: (() -> Void)?

    init(item: ConversationQuickLookItem, sourceView: UIView?) {
        self.item = item
        self.sourceView = sourceView
    }

    func makeController() -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = self
        controller.delegate = self
        controller.view.accessibilityIdentifier = "conversation.quickLook"
        return controller
    }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { item }
    }

    nonisolated func previewController(_ controller: QLPreviewController, transitionViewFor item: any QLPreviewItem) -> UIView? {
        MainActor.assumeIsolated { sourceView }
    }

    nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
        MainActor.assumeIsolated {
            onDismiss?()
            onDismiss = nil
        }
    }

    nonisolated func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode {
        .disabled
    }
}
#endif
