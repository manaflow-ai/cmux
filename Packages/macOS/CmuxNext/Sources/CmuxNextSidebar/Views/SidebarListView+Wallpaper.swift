import CmuxNextDesign

extension SidebarListView: DesktopWallpaperColorFollower {
    /// The desktop picture's color landed: under a group palette that follows it (Wallpaper, Pictorial), the groups take
    /// their new colors (`drawnTints` is worked out by the reload; one per new picture).
    func desktopWallpaperColorDidChange() {
        guard DesignSettings.shared.sidebarSections.groupPalette.followsWallpaper else { return }
        reload(animated: false)
    }
}
