public import Foundation

/// One grouped section of the session index: its key, display title, icon, and rows.
///
/// `title` is plain data set by the caller. For directory sections it is the
/// localized directory display name, and for agent sections the localized agent
/// display name; both are computed app-side (against the app bundle) and passed in,
/// so this type stays a pure value model.
public struct IndexSection: Identifiable, Equatable, Sendable {
    public let key: SectionKey
    public let title: String
    public let icon: SectionIcon
    public let entries: [SessionEntry]

    public init(key: SectionKey, title: String, icon: SectionIcon, entries: [SessionEntry]) {
        self.key = key
        self.title = title
        self.icon = icon
        self.entries = entries
    }

    public var id: SectionKey { key }

    /// Whether to render the "Show more" affordance for this section.
    ///
    /// Directory sections are derived from `scanAll()`'s global, per-agent-capped
    /// pool, so their in-memory `entries` are only a preview that can under-report
    /// a folder's true on-disk session count (issue #6302). "Show more" is the
    /// only trigger for the complete folder-scoped query (`loadDirectorySnapshot`),
    /// so always offer it for directory sections; otherwise a folder that
    /// contributed ≤ `rowLimit` sessions to the capped pool would have the rest of
    /// its sessions permanently unreachable from the UI. Agent sections aren't
    /// folder-truncated this way, so they keep the simple count threshold.
    public func shouldOfferShowMore(rowLimit: Int) -> Bool {
        key.isDirectory || entries.count > rowLimit
    }
}
