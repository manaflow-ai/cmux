import Foundation

/// cmux announcements (R114): signed cards from the feed folder, shown only
/// while the sidebar is revealed; dismissals stay on this Mac.
extension UpdaterService {
    static let dismissedAnnouncementsKey = "cmux.next.announcements.dismissed"

    /// Fetches the signed announcements (when enabled and fetching is on)
    /// and filters them; hidden or fetch-off shows none and touches no network.
    @discardableResult
    public func refreshAnnouncements() -> Task<Void, Never>? {
        guard announcementsEnabled, announcementsFetch else {
            allAnnouncements = []
            announcements = []
            return nil
        }
        let load = announcementsLoader ?? { [releaseNotes] in await releaseNotes?.announcements() ?? [] }
        return Task { [weak self] in
            let all = await load()
            guard let self else { return }
            self.allAnnouncements = all
            self.applyAnnouncementFilter()
        }
    }

    /// A card's x: gone on this Mac for good.
    public func dismissAnnouncement(_ id: String) {
        var dismissed = Set(defaults.stringArray(forKey: Self.dismissedAnnouncementsKey) ?? [])
        dismissed.insert(id)
        defaults.set(dismissed.sorted(), forKey: Self.dismissedAnnouncementsKey)
        applyAnnouncementFilter()
    }

    func applyAnnouncementFilter() {
        guard announcementsEnabled else { announcements = []; return }
        let dismissed = Set(defaults.stringArray(forKey: Self.dismissedAnnouncementsKey) ?? [])
        let shown = AnnouncementFilter.visible(allAnnouncements, build: identity.build, now: now(), dismissed: dismissed)
        if shown != announcements { announcements = shown }
    }
}
