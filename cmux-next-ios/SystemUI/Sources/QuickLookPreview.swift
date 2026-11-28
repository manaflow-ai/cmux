import Foundation
import QuickLook
import UIKit

/// One file as QuickLook sees it: its URL and the title to show (nil shows
/// the file's own name).
final class PreviewItem: NSObject, QLPreviewItem, @unchecked Sendable {
    // Immutable after init; @unchecked only because QLPreviewItem is an
    // NSObjectProtocol.
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL?, title: String) {
        previewItemURL = url
        previewItemTitle = title.isEmpty ? nil : title
    }

    static func items(urls: [URL], titles: [String]) -> [PreviewItem] {
        urls.enumerated().map { offset, url in
            PreviewItem(url: url, title: titles.indices.contains(offset) ? titles[offset] : "")
        }
    }
}

/// A `QLPreviewController` that keeps its own data source and delegate (both
/// are weak on the controller), so the app holds only this controller.
@MainActor
final class PreviewController: QLPreviewController {
    private let coordinator: PreviewCoordinator

    init(
        urls: [URL],
        titles: [String],
        index: Int,
        sourceView: ((Int) -> UIView?)?,
        onDismiss: (() -> Void)?
    ) {
        let items = PreviewItem.items(urls: urls, titles: titles)
        coordinator = PreviewCoordinator(items: items, sourceView: sourceView, onDismiss: onDismiss)
        super.init(nibName: nil, bundle: nil)
        dataSource = coordinator
        delegate = coordinator
        currentPreviewItemIndex = items.indices.contains(index) ? index : 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Points the preview at new files and reloads it.
    func reload(urls: [URL], titles: [String]) {
        coordinator.items = PreviewItem.items(urls: urls, titles: titles)
        // visible-only: QLPreviewController shows one file's page at a time; reloadData re-reads the item count, it draws no rows.
        reloadData()
    }
}

@MainActor
final class PreviewCoordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    var items: [PreviewItem]
    private let sourceView: ((Int) -> UIView?)?
    private var onDismiss: (() -> Void)?

    init(items: [PreviewItem], sourceView: ((Int) -> UIView?)?, onDismiss: (() -> Void)?) {
        self.items = items
        self.sourceView = sourceView
        self.onDismiss = onDismiss
    }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated {
            // QuickLook may still ask while the preview is being torn down.
            guard !items.isEmpty else { return PreviewItem(url: nil, title: "") }
            return items[min(max(index, 0), items.count - 1)]
        }
    }

    nonisolated func previewController(_ controller: QLPreviewController, transitionViewFor item: any QLPreviewItem) -> UIView? {
        // The item's index, by identity: the view it zooms from and back to.
        let identity = ObjectIdentifier(item as AnyObject)
        return MainActor.assumeIsolated {
            guard let sourceView,
                  let index = items.firstIndex(where: { ObjectIdentifier($0) == identity }) else { return nil }
            return sourceView(index)
        }
    }

    nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
        MainActor.assumeIsolated {
            let onDismiss = onDismiss
            self.onDismiss = nil
            onDismiss?()
        }
    }

    nonisolated func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode {
        .disabled
    }
}
