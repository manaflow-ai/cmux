import CmuxCanvas

@MainActor
extension CanvasRootView {
    /// Builds the pane's strip chrome from the latest descriptors.
    func chrome(for pane: CanvasPane) -> CanvasPaneChrome {
        let tabs = pane.panelIds.compactMap { descriptorsByPanelId[$0.rawValue]?.tab }
        let isFocused = pane.panelIds.contains { descriptorsByPanelId[$0.rawValue]?.isFocused == true }
        let closeLabel = descriptorsByPanelId[pane.selectedPanelId.rawValue]?.closeActionLabel
            ?? descriptorsByPanelId.values.first?.closeActionLabel
            ?? ""
        return CanvasPaneChrome(
            tabs: tabs,
            selectedTabId: pane.selectedPanelId.rawValue,
            isFocused: isFocused,
            closeActionLabel: closeLabel
        )
    }
}
