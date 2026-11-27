import AppKit
import Quartz

/// Quick Look for one file from an agent chat's context menu (an image's copy): the shared
/// system preview panel, with this as its source until another file is shown.
@MainActor
final class AgentPaneQuickLook: NSObject, QLPreviewPanelDataSource {
    private var file: URL?

    /// Shows `file` in the Quick Look panel.
    func show(_ file: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.file = file
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // QLPreviewPanel asks its data source on the main thread.
    func numberOfPreviewItems(in panel: QLPreviewPanel?) -> Int {
        file == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel?, previewItemAt index: Int) -> (any QLPreviewItem)? {
        index == 0 ? file as NSURL? : nil
    }
}
