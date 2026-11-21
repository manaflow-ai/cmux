import AppKit

extension AppDelegate {
    func showDragOutWindowFailure() {
        guard let window = NSApp.keyWindow else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.moveTab.failed.title", defaultValue: "Move Failed")
        alert.informativeText = String(localized: "alert.moveTab.failed.message", defaultValue: "cmux could not move this tab to the selected destination.")
        alert.addButton(withTitle: String(localized: "alert.ok", defaultValue: "OK"))
        alert.beginSheetModal(for: window)
    }

    func canMoveSurfaceToNewWindow(panelId: UUID) -> Bool {
        guard let source = locateSurface(surfaceId: panelId),
              let workspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              let panel = workspace.panels[panelId] else { return false }
        return panel is TerminalPanel || panel is BrowserPanel
            || panel is FilePreviewPanel || panel is MarkdownPanel
    }

    /// Creates the target before detaching, then reuses the transactional live-panel move.
    @discardableResult
    func moveSurfaceToNewWindow(panelId: UUID, at screenPoint: NSPoint? = nil) -> UUID? {
        guard canMoveSurfaceToNewWindow(panelId: panelId),
              let source = locateSurface(surfaceId: panelId) else { return nil }
        let windowId = createMainWindow(shouldActivate: false, sourceWindow: mainWindow(for: source.windowId))
        guard let manager = tabManagerFor(windowId: windowId),
              let target = manager.tabs.first(where: { !$0.isChiefHome }) else {
            _ = closeMainWindow(windowId: windowId, recordHistory: false)
            return nil
        }
        let bootstrapPanels = Array(target.panels.keys)
        guard moveSurface(panelId: panelId, toWorkspace: target.id, preserveSourcePaneOnFailure: true) else {
            _ = closeMainWindow(windowId: windowId, recordHistory: false)
            return nil
        }
        for bootstrapId in bootstrapPanels where bootstrapId != panelId {
            _ = target.closePanel(bootstrapId, force: true)
        }
        if let screenPoint, let window = mainWindow(for: windowId) {
            dragOutWindowCoordinator.place(window, near: screenPoint)
        }
        return windowId
    }
}
