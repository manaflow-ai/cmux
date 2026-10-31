import AppKit
import Quartz

/// The items the Quick Look panel shows for a Files pane (Space).
///
/// `QLPreviewPanel` finds its controller through the responder chain;
/// ``FilesPaneView`` answers it and hands the panel this source.
@MainActor
final class QuickLookSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// The selected items, in display order.
    var urls: [URL] = []
    /// Arrow keys in the panel move the pane's cursor (Finder steps through the folder).
    var onKey: ((NSEvent) -> Bool)?

    // An isolated conformance (InferIsolatedConformances), as FileGridCollectionView's:
    // QLPreviewPanel asks its data source and delegate on the main thread.
    func numberOfPreviewItems(in panel: QLPreviewPanel?) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel?, previewItemAt index: Int) -> (any QLPreviewItem)? {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel?, handle event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return onKey?(event) ?? false
    }

    /// Shows or hides the shared panel for `urls`.
    func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// The selection changed: the open panel follows it.
    func refresh() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.reloadData()
    }
}
