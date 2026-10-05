import Foundation

/// cmux announcements (R114): signed cards from the feed folder, shown only
/// while the sidebar is revealed; dismissals stay on this Mac.
extension UpdaterService {
    static let dismissedAnnouncementsKey = "cmux.next.announcements.dismissed"

    /// Red-test stub.
    @discardableResult
    public func refreshAnnouncements() -> Task<Void, Never>? { nil }

    /// Red-test stub.
    public func dismissAnnouncement(_ id: String) {}
}
