public import CmuxNextDaemon
public import CmuxNextSettings
public import Foundation

/// Which local feed items leave the Mac, and with what text
/// (plans/cmux-next/feed.md 9.1 rule 4). Pure, so the driver decides the same
/// way at launch, on each new item and in tests.
///
/// An item is handed off only when `feed.mirrorNotifications` allows its
/// source (agents on; terminal off, title or full) and the alert policy would
/// have alerted for it: its workspace is not muted, its newest text did not
/// arrive in quiet hours, and banners are on for its source. The text is the item's
/// own title and body, scrubbed of known secret shapes; title mode drops the
/// body. An incognito window's item never leaves (leo-workspace
/// design/spaces.md "Incognito"; #31210): handing it off is what puts it in
/// the Feed and pushes it to the iPhone.
public nonisolated struct FeedHandoffPolicy: Sendable {
    public var preferences: NotificationPreferences
    /// Public workspace ids (`ws_…`, an item's `context.workspace`) and
    /// durable keys whose notifications are muted.
    public var mutedWorkspaces: Set<String>
    /// Public workspace and terminal ids (`ws_…`, `term_…`, an item's
    /// `context.workspace` and `context.terminal`) and durable keys of
    /// incognito windows' workspaces: their items stay local.
    public var incognito: Set<String>
    public var calendar: Calendar

    public init(preferences: NotificationPreferences, mutedWorkspaces: Set<String>, incognito: Set<String> = [],
                calendar: Calendar = .current) {
        self.preferences = preferences
        self.mutedWorkspaces = mutedWorkspaces
        self.incognito = incognito
        self.calendar = calendar
    }

    /// The text to hand off for `item`, nil when it stays local.
    public func content(for item: FeedLocalItem) -> (title: String, body: String)? {
        let source = NotificationSource(wire: item.source)
        if let workspace = item.context.workspace, mutedWorkspaces.contains(workspace) { return nil }
        guard !isIncognito(item), preferences.desktop != .never, preferences.postsDesktop(for: source),
              !arrivedInQuietHours(item) else { return nil }
        return mirrored(item)
    }

    /// The text for an item that is already handing off: it must reach its
    /// new owner (a send that may have committed never unfreezes), but only
    /// what the mirror setting allows now leaves the Mac, and nothing of an
    /// incognito window's item (one whose window turned incognito after it froze).
    public func frozenContent(for item: FeedLocalItem) -> (title: String, body: String) {
        isIncognito(item) ? ("", "") : mirrored(item) ?? ("", "")
    }

    private func isIncognito(_ item: FeedLocalItem) -> Bool {
        [item.context.workspace, item.context.terminal].contains { $0.map(incognito.contains) ?? false }
    }

    private func mirrored(_ item: FeedLocalItem) -> (title: String, body: String)? {
        let mirror = preferences.feedMirror
        let text: (String, String)?
        switch NotificationSource(wire: item.source) {
        case .terminal:
            switch mirror.terminal {
            case .off: text = nil
            case .title: text = (item.title, "")
            case .full: text = (item.title, item.body)
            }
        default:
            text = mirror.agents ? (item.title, item.body) : nil
        }
        return text.map { ($0.0.secretsScrubbedPrefix, $0.1.secretsScrubbedPrefix) }
    }

    private func arrivedInQuietHours(_ item: FeedLocalItem) -> Bool {
        guard let quiet = preferences.quietHours else { return false }
        let date = Date(timeIntervalSince1970: Double(item.updatedAtMs) / 1000)
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return quiet.contains(minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}
