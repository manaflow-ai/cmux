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

#if DEBUG
extension SidebarWorkspaceRowTableCellView {
    /// Test convenience that supplies the default palette matching the row's
    /// explicit color scheme. Production call sites pass the runtime palette.
    func configure(
        model: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions,
        isPointerHovering: Bool,
        contextMenuDidOpen: @escaping () -> Void,
        contextMenuDidClose: @escaping () -> Void
    ) {
        configure(
            model: model,
            actions: actions,
            chromePalette: ChromePalette.resolve(
                theme: .default,
                colorScheme: model.colorSchemeIsDark ? .dark : .light
            ),
            isPointerHovering: isPointerHovering,
            contextMenuDidOpen: contextMenuDidOpen,
            contextMenuDidClose: contextMenuDidClose
        )
    }
}
#endif
