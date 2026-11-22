public import Foundation

/// The staged update card above the footer (UPDATE-CARD): the App fills it
/// from the updater only while an update is staged or installing. The
/// button sends `SidebarIntent.installUpdate`, the checkbox
/// `setAutomaticUpdates`, a link in the hover popover `openUpdateLink`.
/// All text arrives localized.
public nonisolated struct SidebarUpdateCard: Hashable, Sendable {
    /// "cmux <version> is ready".
    public var title: String
    /// "Restart to Update", or "Installing…" while disabled.
    public var buttonTitle: String
    /// False while the update installs (the click was taken).
    public var isEnabled: Bool
    public var automaticUpdatesTitle: String
    /// The Automatic Updates checkbox (`updates.downloadAutomatically`).
    public var automaticUpdates: Bool
    /// The hover popover.
    public var notes: Notes

    public init(title: String, buttonTitle: String, isEnabled: Bool = true, automaticUpdatesTitle: String,
                automaticUpdates: Bool, notes: Notes) {
        self.title = title
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
