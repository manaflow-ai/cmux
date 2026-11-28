#if os(iOS)
import CmuxConversationCore
import CmuxMobileSystemUIBridge
import UIKit
import os

/// One attachment as Quick Look sees it: a local copy and the title Messages
/// shows ("Photo" for a photo, the file name for a document).
final class ConversationQuickLookItem: Sendable {
    let previewItemURL: URL
    let previewItemTitle: String

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
///
/// Quick Look itself lives in CmuxMobileSystemUI.framework, loaded on first
/// use (linked, it costs the app's launch about 1.55 s); editing is off there.
@MainActor
final class ConversationQuickLookPresenter {
    private static let log = Logger(subsystem: "dev.cmux.mobile", category: "ConversationQuickLook")

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

    /// The Quick Look controller, or nil when the framework did not load
    /// (logged; nothing opens).
    func makeController() -> UIViewController? {
        guard let provider = SystemUI.provider else {
            Self.log.error("quick look not shown: CmuxMobileSystemUI did not load")
            return nil
        }
        let opening = index
        let controller = provider.makePreviewController(
            urls: items.map(\.previewItemURL),
            titles: items.map(\.previewItemTitle),
            index: opening,
            // Only the opening item zooms from its bubble.
            sourceView: { [weak self] item in
                guard item == opening else { return nil }
                return self?.sourceView
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                let onDismiss = self.onDismiss
                self.onDismiss = nil
                onDismiss?()
            }
        )
        controller.view.accessibilityIdentifier = "conversation.quickLook"
        return controller
    }
}
#endif
