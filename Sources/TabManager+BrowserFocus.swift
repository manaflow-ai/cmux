import AppKit

extension TabManager {
    /// Resolves a browser panel from explicit command-action identities without
    /// consulting or mutating the visible workspace selection.
    func browserPanel(workspaceID: UUID, panelID: UUID) -> BrowserPanel? {
        guard let workspace = tabs.first(where: { $0.id == workspaceID }) else { return nil }
        return workspace.browserPanel(for: panelID)
    }

    /// Activates an exact browser target before the caller requests address-bar
    /// focus. This prevents a background-target action from leaving a focus
    /// request queued against an invisible workspace.
    func activateBrowserPanelForAddressBarFocus(
        workspaceID: UUID,
        panelID: UUID
    ) -> BrowserPanel? {
        guard let workspace = tabs.first(where: { $0.id == workspaceID }),
              let panel = workspace.browserPanel(for: panelID) else {
            return nil
        }
        focusTab(
            workspaceID,
            surfaceId: panelID,
            suppressFlash: true,
            focusIntent: .browser(.webView)
        )
        guard selectedTabId == workspaceID,
              workspace.focusedPanelId == panelID,
              workspace.browserPanel(for: panelID) === panel else {
            return nil
        }
        return panel
    }

    /// Resolves a text-file preview from explicit command-action identities.
    func textFilePreviewPanel(workspaceID: UUID, panelID: UUID) -> FilePreviewPanel? {
        guard let workspace = tabs.first(where: { $0.id == workspaceID }),
              let panel = workspace.panels[panelID] as? FilePreviewPanel,
              panel.previewMode == .text else { return nil }
        return panel
    }

    /// Resolves a rendered Markdown preview from explicit command-action
    /// identities. Raw text-edit mode intentionally remains excluded.
    func markdownPreviewPanel(workspaceID: UUID, panelID: UUID) -> MarkdownPanel? {
        guard let workspace = tabs.first(where: { $0.id == workspaceID }),
              let panel = workspace.panels[panelID] as? MarkdownPanel,
              panel.displayMode == .preview else { return nil }
        return panel
    }

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

    /// Zooms an explicitly targeted browser or text-file preview panel.
    @discardableResult
    func zoomInBrowserOrTextFilePreview(workspaceID: UUID, panelID: UUID) -> Bool {
        if let preview = textFilePreviewPanel(workspaceID: workspaceID, panelID: panelID) {
            return preview.zoomTextPreviewIn()
        }
        return browserPanel(workspaceID: workspaceID, panelID: panelID)?.zoomIn() ?? false
    }

    /// Zooms out an explicitly targeted browser or text-file preview panel.
    @discardableResult
    func zoomOutBrowserOrTextFilePreview(workspaceID: UUID, panelID: UUID) -> Bool {
        if let preview = textFilePreviewPanel(workspaceID: workspaceID, panelID: panelID) {
            return preview.zoomTextPreviewOut()
        }
        return browserPanel(workspaceID: workspaceID, panelID: panelID)?.zoomOut() ?? false
    }

    /// Resets zoom for an explicitly targeted browser or text-file preview.
    @discardableResult
    func resetZoomBrowserOrTextFilePreview(workspaceID: UUID, panelID: UUID) -> Bool {
        if let preview = textFilePreviewPanel(workspaceID: workspaceID, panelID: panelID) {
            return preview.resetTextPreviewZoom()
        }
        return browserPanel(workspaceID: workspaceID, panelID: panelID)?.resetZoom() ?? false
    }

    @discardableResult
    func zoomInMarkdown(workspaceID: UUID, panelID: UUID) -> Bool {
        markdownPreviewPanel(workspaceID: workspaceID, panelID: panelID)?.zoomIn() ?? false
    }

    @discardableResult
    func zoomOutMarkdown(workspaceID: UUID, panelID: UUID) -> Bool {
        markdownPreviewPanel(workspaceID: workspaceID, panelID: panelID)?.zoomOut() ?? false
    }

    @discardableResult
    func resetZoomMarkdown(workspaceID: UUID, panelID: UUID) -> Bool {
        markdownPreviewPanel(workspaceID: workspaceID, panelID: panelID)?.resetZoom() ?? false
    }

    @discardableResult
    func setBrowserFocusMode(
        workspaceID: UUID,
        panelID: UUID,
        enabled: Bool,
        reason: String
    ) -> BrowserStateMutationOutcome {
        guard let workspace = tabs.first(where: { $0.id == workspaceID }),
              let panel = workspace.browserPanel(for: panelID) else {
            return .failed
        }
        guard panel.isBrowserFocusModeActive != enabled else {
            return .alreadySatisfied
        }
        if enabled,
           panel.searchState == nil,
           workspace.focusedPanelId != panelID {
            workspace.clearSplitZoom()
            workspace.focusPanel(panelID)
        }
        return panel.setBrowserFocusModeActive(
            enabled,
            reason: reason,
            focusWebView: true
        ) ? .completed : .failed
    }

    @discardableResult
    func setBrowserOmnibar(
        workspaceID: UUID,
        panelID: UUID,
        enabled: Bool
    ) -> BrowserStateMutationOutcome {
        guard let panel = browserPanel(workspaceID: workspaceID, panelID: panelID) else {
            return .failed
        }
        guard panel.isOmnibarVisible != enabled else {
            return .alreadySatisfied
        }
        return panel.setOmnibarVisible(enabled) ? .completed : .failed
    }

    @discardableResult
    func setBrowserDeveloperTools(
        workspaceID: UUID,
        panelID: UUID,
        enabled: Bool
    ) -> BrowserStateMutationOutcome {
        guard let panel = browserPanel(workspaceID: workspaceID, panelID: panelID) else {
            return .failed
        }
        guard panel.developerToolsVisibilityIntent != enabled else {
            return .alreadySatisfied
        }
        return panel.setDeveloperToolsVisible(enabled) ? .queued : .failed
    }

    @discardableResult
    func setBrowserReactGrab(
        workspaceID: UUID,
        panelID: UUID,
        enabled: Bool,
        focusWebView: Bool
    ) -> BrowserStateMutationOutcome {
        guard let workspace = tabs.first(where: { $0.id == workspaceID }),
              let panel = workspace.browserPanel(for: panelID) else {
            return .failed
        }
        guard panel.reactGrabActivationIntent != enabled else {
            return .alreadySatisfied
        }

        if focusWebView {
            if workspace.focusedPanelId != panelID {
                workspace.clearSplitZoom()
                workspace.focusPanel(panelID)
            }
            _ = panel.requestExplicitWebViewFocus()
        }
        return panel.requestReactGrabActive(enabled, reason: "commandPalette")
            ? .queued
            : .failed
    }

    @discardableResult
    func toggleBrowserFocusMode(workspaceID: UUID, panelID: UUID, reason: String) -> Bool {
        guard let panel = browserPanel(workspaceID: workspaceID, panelID: panelID) else { return false }
        return setBrowserFocusMode(
            workspaceID: workspaceID,
            panelID: panelID,
            enabled: !panel.isBrowserFocusModeActive,
            reason: reason
        ).wasAccepted
    }

    @discardableResult
    func toggleBrowserOmnibar(workspaceID: UUID, panelID: UUID) -> Bool {
        guard let panel = browserPanel(workspaceID: workspaceID, panelID: panelID) else { return false }
        return setBrowserOmnibar(
            workspaceID: workspaceID,
            panelID: panelID,
            enabled: !panel.isOmnibarVisible
        ).wasAccepted
    }

    @discardableResult
    func toggleBrowserDeveloperTools(workspaceID: UUID, panelID: UUID) -> Bool {
        guard let panel = browserPanel(workspaceID: workspaceID, panelID: panelID) else { return false }
        return setBrowserDeveloperTools(
            workspaceID: workspaceID,
            panelID: panelID,
            enabled: !panel.developerToolsVisibilityIntent
        ).wasAccepted
    }

    @discardableResult
    func showBrowserJavaScriptConsole(workspaceID: UUID, panelID: UUID) -> Bool {
        browserPanel(workspaceID: workspaceID, panelID: panelID)?.showDeveloperToolsConsole() ?? false
    }
}
