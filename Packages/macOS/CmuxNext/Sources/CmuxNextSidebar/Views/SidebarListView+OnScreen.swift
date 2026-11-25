import AppKit

extension SidebarListViewComponents {
    /// A workspace row's fills under the primary selection's: multi-selected, or on screen in this window
    /// (`SidebarModel.onScreen`, Debug Settings `sidebar.multiView`), so the sidebar shows every workspace
    /// the window shows and the focused one strongest.
    func paintSecondaryFills(_ row: WorkspaceRowView, _ id: WorkspaceID) {
        row.isSecondarySelected = model.selection.contains(id) && !row.isSelected
        row.isOnScreen = SidebarTunables.multiViewOn && model.onScreen.contains(id) && !row.isSelected
    }
}
