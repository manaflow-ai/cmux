/// A window's space restored, not switched (Leo 2026-10-15): at launch the window first shows
/// the space saved with it, then the daemon's; the list shows that one at once, with no slide.
extension SidebarModel {
    /// Shows `id` as a restore: the next list change shows it with no slide (R99 slides a switch).
    public func restoreActiveProfile(_ id: ProfileKey?) {
        guard activeProfileID != id else { return }
        restoresActiveProfile = true
        activeProfileID = id
    }

    /// Whether the active space's last change was a restore; reading it clears it.
    func takeRestore() -> Bool {
        defer { restoresActiveProfile = false }
        return restoresActiveProfile
    }
}
