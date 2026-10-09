import CmuxNextHistory

// Chief decision 2026-10-09: the sidebar has no Back, so Go Back must
// always leave a top page. A page shown as a window's first step (a fresh
// launch that restored Home or a workspace with no trail entry yet) first
// records where the window was (TopPageOriginTrailTests).
extension WindowController {
    /// Where this window is now, as a trail location: the top page it
    /// shows, else its workspace's focused tab. Nil when neither is known.
    var trailOrigin: HistoryLocation? {
        if let route = shownTopPage {
            return .page(route.rawValue, window: state.id, title: topPages.title(for: route),
                         isIncognito: services.windows.isIncognito(window: state.id))
        }
        return services.locationTrail.location(of: focus.state, in: self, anyTarget: true)
    }
}

extension LocationTrailService {

    /// Whether `origin` must be recorded before showing `page`: the trail's
    /// current entry is not already where the window was, and the window
    /// was not already on that page.
    nonisolated static func needsOrigin(_ origin: HistoryLocation, before page: HistoryLocation, current: HistoryLocation?) -> Bool {
        guard !origin.isSameSidebarItem(as: page) else { return false }
        guard let current else { return true }
        return current.key != origin.key && !current.isSameSidebarItem(as: origin)
    }
}
