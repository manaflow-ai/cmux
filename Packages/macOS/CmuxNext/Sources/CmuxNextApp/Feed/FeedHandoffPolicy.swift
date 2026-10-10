import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// Which local feed items leave the Mac, and with what text
/// (plans/cmux-next/feed.md 9.1 rule 4). Pure, so the driver decides the same
/// way at launch, on each new item and in tests.
///
/// An item is handed off only when `feed.mirrorNotifications` allows its
/// source (agents on; terminal off, title or full) and the alert policy would
/// have alerted for it: its workspace is not muted, its newest text did not
/// arrive in quiet hours, and banners are on for its source. The text is the item's
/// own title and body, scrubbed of known secret shapes; title mode drops the
/// body.
nonisolated struct FeedHandoffPolicy: Sendable {
    var preferences: NotificationPreferences
    /// Public workspace ids (`ws_…`, an item's `context.workspace`) and
    /// durable keys whose notifications are muted.
    var mutedWorkspaces: Set<String>
    var calendar: Calendar = .current

    /// The text to hand off for `item`, nil when it stays local.
    func content(for item: FeedLocalItem) -> (title: String, body: String)? {
        let source = NotificationCenterService.source(item.source)
        if let workspace = item.context.workspace, mutedWorkspaces.contains(workspace) { return nil }
        guard preferences.desktop != .never, preferences.postsDesktop(for: source), !arrivedInQuietHours(item) else { return nil }
        return mirrored(item)
    }

    /// The text for an item that is already handing off: it must reach its
    /// new owner (a send that may have committed never unfreezes), but only
    /// what the mirror setting allows now leaves the Mac.
    func frozenContent(for item: FeedLocalItem) -> (title: String, body: String) {
        mirrored(item) ?? ("", "")
    }

    private func mirrored(_ item: FeedLocalItem) -> (title: String, body: String)? {
        let mirror = preferences.feedMirror
        let text: (String, String)?
        switch NotificationCenterService.source(item.source) {
        case .terminal:
            switch mirror.terminal {
            case .off: text = nil
            case .title: text = (item.title, "")
            case .full: text = (item.title, item.body)
            }
        default:
            text = mirror.agents ? (item.title, item.body) : nil
        }
        return text.map { (FeedSecretScrubber.scrub($0.0), FeedSecretScrubber.scrub($0.1)) }
    }

    private func arrivedInQuietHours(_ item: FeedLocalItem) -> Bool {
        guard let quiet = preferences.quietHours else { return false }
        let date = Date(timeIntervalSince1970: Double(item.updatedAtMs) / 1000)
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return quiet.contains(minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}
