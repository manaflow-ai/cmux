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
/// the share button (Save to Files, Save Image, AirDrop). With several
/// items (a message's documents, the composer's queued attachments) it
/// opens at `index` and swipes sideways between them; only the opening item
/// zooms from `sourceView`.
@MainActor
final class ConversationQuickLookPresenter: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    private let items: [ConversationQuickLookItem]
    private let index: Int
    private weak var sourceView: UIView?
    /// Called when the preview has closed (the bubble shows again).
    var onDismiss: (() -> Void)?

    convenience init(item: ConversationQuickLookItem, sourceView: UIView?) {
        self.init(items: [item], index: 0, sourceView: sourceView)
    }

    init(items: [ConversationQuickLookItem], index: Int, sourceView: UIView?) {
        self.items = items
        self.index = items.indices.contains(index) ? index : 0
        self.sourceView = sourceView
    }

    func makeController() -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = self
        controller.delegate = self
        controller.currentPreviewItemIndex = index
        controller.view.accessibilityIdentifier = "conversation.quickLook"
        return controller
    }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { items[min(max(index, 0), items.count - 1)] }
    }

    nonisolated func previewController(_ controller: QLPreviewController, transitionViewFor item: any QLPreviewItem) -> UIView? {
        // Only the opening item zooms from its bubble (compared by identity).
        let opening = ObjectIdentifier(item as AnyObject)
        return MainActor.assumeIsolated {
            guard items.indices.contains(index), ObjectIdentifier(items[index]) == opening else { return nil }
            return sourceView
        }
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
