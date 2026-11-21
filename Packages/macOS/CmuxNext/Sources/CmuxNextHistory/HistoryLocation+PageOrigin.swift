// Chief decision 2026-10-09: the sidebar has no Back, so Go Back must always leave a top page.
extension HistoryLocation {
    /// Whether `origin` must be recorded before showing `page`: the trail's
    /// current entry is not already where the window was, and the window
    /// was not already on that page.
    public static func needsOrigin(_ origin: HistoryLocation, before page: HistoryLocation, current: HistoryLocation?) -> Bool {
        guard !origin.isSameSidebarItem(as: page) else { return false }
        guard let current else { return true }
        return current.key != origin.key && !current.isSameSidebarItem(as: origin)
    }
}
