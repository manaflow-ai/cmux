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
/// the Feed and pushes it to the iPhone. So an item leaves only once the
/// workspace or terminal it names is known to be a normal window's
/// (`normalWindows`).
public nonisolated struct FeedHandoffPolicy: Sendable {
    public var preferences: NotificationPreferences
    /// Public workspace ids (`ws_…`, an item's `context.workspace`) and
    /// durable keys whose notifications are muted.
    public var mutedWorkspaces: Set<String>
    /// Public workspace and terminal ids (`ws_…`, `term_…`, an item's
    /// `context.workspace` and `context.terminal`) and durable keys of the
    /// workspaces in normal windows now. An item naming none of them stays
    /// local: an incognito window's, one with no context, and one whose workspace is not classified
    /// yet or is gone (it may have been incognito; a crash may have left it
    /// handing off). nil: no item is held back for this.
    public var normalWindows: Set<String>?
    /// False until the app knows which workspaces are incognito (windows restored, ephemeral flags read): until
    /// then no pass runs, so neither an open item nor a frozen one leaves with too much or too little text.
    public var classified: Bool
    public var calendar: Calendar

    public init(preferences: NotificationPreferences, mutedWorkspaces: Set<String>, normalWindows: Set<String>? = nil,
                classified: Bool = true, calendar: Calendar = .current) {
        self.preferences = preferences
        self.mutedWorkspaces = mutedWorkspaces
        self.normalWindows = normalWindows
        self.classified = classified
        self.calendar = calendar
    }

    /// The text to hand off for `item`, nil when it stays local.
    public func content(for item: FeedLocalItem) -> (title: String, body: String)? {
        let source = NotificationSource(wire: item.source)
        if let workspace = item.context.workspace, mutedWorkspaces.contains(workspace) { return nil }
        guard isInNormalWindow(item), preferences.desktop != .never, preferences.postsDesktop(for: source),
              !arrivedInQuietHours(item) else { return nil }
        return mirrored(item)
    }

    /// The text for an item that is already handing off: only what the mirror
    /// setting allows now leaves the Mac. Nil for an item not known to be a
    /// normal window's (`normalWindows`): the driver withdraws its adopt
    /// (`feed.adopt.cancel`) instead of sending it.
    public func frozenContent(for item: FeedLocalItem) -> (title: String, body: String)? {
        isInNormalWindow(item) ? mirrored(item) ?? ("", "") : nil
    }

    private func isInNormalWindow(_ item: FeedLocalItem) -> Bool {
        // No context (`cmux notify --workspace` with no tab) names nothing to classify: it stays local. The
        // daemon posts such a notice read, so it never handed off anyway (feed_local.rs `feed_notice`).
        guard let normalWindows else { return true }
        return [item.context.workspace, item.context.terminal].contains { $0.map(normalWindows.contains) ?? false }
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
