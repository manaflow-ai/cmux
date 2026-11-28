import Foundation

/// One chrome's side of zoom per site: when its page commits on another
/// host, the page takes that host's level (100% when none is stored); when
/// the user zooms, the level is stored for the host, and every other chrome
/// showing that host in the same browser profile follows.
@MainActor
final class SiteZoomFollower {
    var levels: SiteZoomLevels = .shared {
        didSet { observe() }
    }
    private weak var tab: (any BrowserTab)?
    private var loop: ObservationLoop?
    private var host: String?

    init() { observe() }

    /// Follows `tab` (the chrome's page; a hibernated or swapped page
    /// starts over).
    func follow(_ tab: any BrowserTab) {
        self.tab = tab
        host = nil
        loop?.cancel()
        loop = ObservationLoop { [weak self, weak tab] in
            guard let tab else { return }
            let committed = tab.state.url?.host()?.lowercased()
            self?.hostDidChange(committed)
        }
    }

    /// The user zoomed the page (Cmd-+, Cmd--, Cmd-0, the menu).
    func userDidZoom() {
        guard let tab, let host = tab.state.url?.host() else { return }
        levels.set(tab.state.zoom, host: host, profile: tab.profileID)
    }

    private func hostDidChange(_ committed: String?) {
        guard committed != host else { return }
        let first = host == nil
        host = committed
        // A page's first host with no stored level keeps a zoom the tab
        // already has (its record restored it, from before zoom per site).
        if first, let tab, let committed, levels.level(host: committed, profile: tab.profileID) == nil, abs(tab.state.zoom - 1) > 0.001 {
            return levels.set(tab.state.zoom, host: committed, profile: tab.profileID)
        }
        apply()
    }

    private func apply() {
        guard let tab, let host else { return }
        let level = levels.level(host: host, profile: tab.profileID) ?? 1
        if abs(tab.state.zoom - level) > 0.001 { tab.setZoom(level) }
    }

    private func observe() {
        let observed = levels
        levels.observe { [weak self] profile, host in
            guard let self, self.levels === observed else { return false }
            if let tab, tab.profileID == profile, self.host == host { apply() }
            return true
        }
    }
}
