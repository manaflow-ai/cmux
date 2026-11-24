import CmuxNextDesign

extension SidebarListView: DesktopWallpaperColorFollower {
    /// The desktop picture's color landed: under the Pictorial palette the groups take their new bands (`drawnTints` is
    /// worked out by the reload; one per new picture). The Wallpaper palette's headers repaint on their own
    /// (`DesignSettings.groupWallpaperTint` is observed).
    func desktopWallpaperColorDidChange() {
        guard DesignSettings.shared.sidebarSections.groupPalette == .pictorial else { return }
        reload(animated: false)
    }
}
