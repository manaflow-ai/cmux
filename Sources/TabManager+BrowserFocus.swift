import AppKit

extension TabManager {
    /// Returns the focused panel if it is a main-area or Dock browser.
    var focusedBrowserPanel: BrowserPanel? {
        guard let tab = selectedWorkspace else { return nil }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let window, let responder = window.firstResponder {
            if let addressBarPanelId = AppDelegate.shared?.focusedBrowserAddressBarPanelId(),
               browserOmnibarPanelId(for: responder) == addressBarPanelId,
               let browser = tab.browserPanelIncludingDock(for: addressBarPanelId) {
                return browser
            }
            if let context = BrowserWindowPortalRegistry.paneDropContext(owning: responder, in: window),
               context.workspaceId == tab.id,
               let browser = tab.browserPanelIncludingDock(for: context.panelId) {
                return browser
            }
        }
        if let panelId = tab.focusedPanelId,
           let browser = tab.panels[panelId] as? BrowserPanel {
            return browser
        }
        return nil
    }

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
