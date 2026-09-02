import CmuxSettings

extension SidebarWorkspaceRowTableCellView {
    func configurePresentation(
        model: SidebarWorkspaceRowModel,
        chromePalette: ChromePalette
    ) {
        let previous = self.model
        let paletteChanged = self.chromePalette != chromePalette
        suspendPresentation()
        guard previous != model || paletteChanged else { return }
        if previous?.workspaceId != model.workspaceId {
            invalidateLinkAccessibility()
        }
        self.model = model
        self.chromePalette = chromePalette
        applyModel(model)
        needsLayout = true
    }

    /// Repaints the represented row without rebuilding its action presentation.
    func setChromePalette(_ palette: ChromePalette) {
        guard chromePalette != palette else { return }
        chromePalette = palette
        guard let model else { return }
        applyModel(model)
        needsLayout = true
    }
}
