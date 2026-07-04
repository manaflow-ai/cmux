import AppKit

extension TabManager {
    var focusedTextFilePreviewPanel: FilePreviewPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let panel = tab.panels[panelId] as? FilePreviewPanel,
              panel.previewMode == .text else { return nil }
        return panel
    }

    /// Returns the focused panel if it's a MarkdownPanel showing the rendered
    /// preview, nil otherwise. Zoom applies to the preview WKWebView, so the raw
    /// text-edit mode is deliberately excluded.
    var focusedMarkdownPanel: MarkdownPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let panel = tab.panels[panelId] as? MarkdownPanel,
              panel.displayMode == .preview else { return nil }
        return panel
    }

    @discardableResult
    func zoomInFocusedTextFilePreview() -> Bool {
        performFocusedTextFilePreviewZoom { $0.zoomTextPreviewIn() } ?? false
    }

    @discardableResult
    func zoomOutFocusedTextFilePreview() -> Bool {
        performFocusedTextFilePreviewZoom { $0.zoomTextPreviewOut() } ?? false
    }

    @discardableResult
    func resetZoomFocusedTextFilePreview() -> Bool {
        performFocusedTextFilePreviewZoom { $0.resetTextPreviewZoom() } ?? false
    }

    @discardableResult
    func zoomInFocusedBrowserOrTextFilePreview() -> Bool {
        if let result = performFocusedTextFilePreviewZoom({ $0.zoomTextPreviewIn() }) { return result }
        return zoomInFocusedBrowser()
    }

    @discardableResult
    func zoomOutFocusedBrowserOrTextFilePreview() -> Bool {
        if let result = performFocusedTextFilePreviewZoom({ $0.zoomTextPreviewOut() }) { return result }
        return zoomOutFocusedBrowser()
    }

    @discardableResult
    func resetZoomFocusedBrowserOrTextFilePreview() -> Bool {
        if let result = performFocusedTextFilePreviewZoom({ $0.resetTextPreviewZoom() }) { return result }
        return resetZoomFocusedBrowser()
    }
}
