import AppKit
import Bonsplit

@MainActor
extension DockSplitStore {
    func browserWebExtensionOrderedPanelIDs() -> [UUID] {
        var orderedPanelIDs = bonsplitController.allTabIds.compactMap { surfaceIdToPanelId[$0] }
        let orderedSet = Set(orderedPanelIDs)
        orderedPanelIDs.append(contentsOf: panels.keys
            .filter { !orderedSet.contains($0) }
            .sorted { $0.uuidString < $1.uuidString })
        return orderedPanelIDs
    }

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

    func noteBrowserWebExtensionSelection(_ selectedPanel: any Panel) {
        let nativeWindow = AppDelegate.shared?.dockReferenceTabManager(for: self)?.window
            ?? panels.values.lazy.compactMap { panel in
                guard let browserPanel = panel as? BrowserPanel else { return nil }
                return browserPanel.webView.window ?? browserPanel.portalAnchorView.window
            }.first
        browserWebExtensionHost?.noteSelectionChanged(
            selectedBrowserPanelID: (selectedPanel as? BrowserPanel)?.id,
            nativeWindow: nativeWindow
        )
    }

    func splitTabBar(_: BonsplitController, didChangeGeometry _: LayoutSnapshot) {
        AppDelegate.shared?
            .dockReferenceTabManager(for: self)?
            .reconcileBrowserWebExtensionTabOrder()
    }
}
