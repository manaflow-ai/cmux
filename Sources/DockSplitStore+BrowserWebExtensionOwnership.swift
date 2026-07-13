import AppKit

@MainActor
extension DockSplitStore {
    func reconcileBrowserWebExtensionWindows(
        in nativeWindow: NSWindow?,
        activateFocusedPanel: Bool = true
    ) {
        guard let nativeWindow else { return }
        for browserPanel in panels.values.compactMap({ $0 as? BrowserPanel }) {
            browserPanel.browserWebExtensionHost?.noteWindowChanged(
                panelID: browserPanel.id,
                nativeWindow: nativeWindow
            )
        }
        if activateFocusedPanel,
           let focusedPanelId,
           let browserPanel = panels[focusedPanelId] as? BrowserPanel {
            browserPanel.noteWebExtensionActivated()
        }
    }
}
