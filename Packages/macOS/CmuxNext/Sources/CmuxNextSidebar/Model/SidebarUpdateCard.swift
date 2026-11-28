public import Foundation

/// The staged update card above the footer (UPDATE-CARD): the App fills it
/// from the updater only while an update is staged or installing. The
/// button sends `SidebarIntent.installUpdate`, the checkbox
/// `setAutomaticUpdates`, its accessibility action "See all changes"
/// `openUpdateChanges`; its Hide button (UPDATE-CARD-CLOSE: one click hides
/// this version until a newer one) and its right-click menu (hide, Remind Me
/// in 1 Day / 3 Days / 1 Week) `noticeAction(card: id, action:)`. The full build, the highlights and "See all
/// changes" are the hover popover's (Leo 2026-10-13: the card and the
/// popover never repeat a fact). All text arrives localized.
public nonisolated struct SidebarUpdateCard: Hashable, Sendable {
    /// "Update Ready".
    public var title: String
    /// The short version and build date ("nightly 3845050 · Oct 13"), nil when unknown.
    public var detail: String?
    /// "See all changes" (`openUpdateChanges`): an accessibility action of the card's button
    /// only (the popup, which shows it, opens on hover); nil leaves it out.
    public var seeAllTitle: String?
    /// "Restart to Update", or "Installing…" while disabled.
    public var buttonTitle: String
    /// False while the update installs (the click was taken).
    public var isEnabled: Bool
    public var automaticUpdatesTitle: String
    /// The Automatic Updates checkbox (`updates.downloadAutomatically`).
    public var automaticUpdates: Bool
    /// The hover popover.
    public var notes: Notes
    /// The card id its Hide button and menu items are sent with (`noticeAction(card:action:)`).
    public var id: String
    /// The default ``id`` (UPDATE-CARD-CLOSE).
    public static let cardID = "update-ready"
    /// The Hide button: its text ("Hide"), its tooltip and VoiceOver label
    /// ("Hide Until a Newer Version") and the action id one click sends; a nil
    /// title shows no button (while installing).
    public var closeTitle: String?
    public var closeLabel: String?
    public var closeAction: String?
    /// The card's right-click menu: each item sends `noticeAction(card: id, action: item.id)`.
    public var closeMenu: [SidebarNoticeCard.Action]

    public init(title: String, detail: String? = nil, seeAllTitle: String? = nil, buttonTitle: String, isEnabled: Bool = true, automaticUpdatesTitle: String,
                automaticUpdates: Bool, notes: Notes, id: String = SidebarUpdateCard.cardID, closeTitle: String? = nil,
                closeLabel: String? = nil, closeAction: String? = nil, closeMenu: [SidebarNoticeCard.Action] = []) {
        self.id = id
        self.closeTitle = closeTitle
        self.closeLabel = closeLabel
        self.closeAction = closeAction
        self.closeMenu = closeMenu
        self.title = title
        self.detail = detail
        self.seeAllTitle = seeAllTitle
        self.buttonTitle = buttonTitle
        self.isEnabled = isEnabled
        self.automaticUpdatesTitle = automaticUpdatesTitle
        self.automaticUpdates = automaticUpdates
        self.notes = notes
    }

    /// The popover: what a click does, that sessions keep running, the
    /// newest changes and a link to the rest.
    public struct Notes: Hashable, Sendable {
        public var headline: String
        public var keepsRunning: String
        /// "What's changed", nil without changes.
        public var whatsChangedTitle: String?
        /// Newest first.
        public var changes: [Change]
        /// "N more changes", nil without a link.
        public var moreTitle: String?
        public var moreURL: URL?

        public init(headline: String, keepsRunning: String, whatsChangedTitle: String? = nil, changes: [Change] = [],
                    moreTitle: String? = nil, moreURL: URL? = nil) {
            self.headline = headline
            self.keepsRunning = keepsRunning
            self.whatsChangedTitle = whatsChangedTitle
            self.changes = changes
            self.moreTitle = moreTitle
            self.moreURL = moreURL
        }
    }

    /// One change: its title, author (when known) and pull request link.
    public struct Change: Hashable, Sendable {
        public var title: String
        public var author: String?
        /// "#1234".
        public var linkTitle: String?
        public var url: URL?

        public init(title: String, author: String? = nil, linkTitle: String? = nil, url: URL? = nil) {
            self.title = title
            self.author = author
            self.linkTitle = linkTitle
            self.url = url
        }
    }
}
