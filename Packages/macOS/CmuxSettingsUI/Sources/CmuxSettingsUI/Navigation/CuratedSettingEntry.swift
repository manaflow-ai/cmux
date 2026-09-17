import CmuxSettings
import Foundation

/// A single user-curated search entry surfaced by ``SettingsSearchIndex``.
///
/// Each entry pairs a navigable ``SettingsSectionID`` with a stable id,
/// localized row text, the cmux.json paths owned by that row, and a
/// search synonym string mined from how users actually refer to the
/// setting (the legacy `SettingsSearchAliasIndex` table is the source).
///
/// Hosts that want to expose extra settings in search can build
/// additional ``CuratedSettingEntry`` values and pass them to
/// ``SettingsSearchIndex/init(catalog:curatedEntries:)``; the
/// package-shipped default table is the value of the
/// `[CuratedSettingEntry].cmuxDefault` constant.
public struct CuratedSettingEntry: Sendable, Hashable {
    /// Section that will be selected in the sidebar when the user
    /// clicks this search hit.
    public let section: SettingsSectionID

    /// Stable identifier for this entry within its section. Used to
    /// dedupe entries and to build the index's stable entry id.
    public let id: String

    /// User-facing title rendered in the search result row.
    public let title: String

    /// User-facing detail text from the row's subtitle, note, or helper
    /// copy. Included in search text but not rendered in the sidebar.
    public let detailText: String

    /// Dotted cmux.json paths that should scroll to this search entry's
    /// row. These mirror ``SettingsConfigurationReview`` paths used by
    /// the actual row.
    public let paths: [String]

    /// Space-separated synonym tokens. The search index folds these
    /// case- and diacritic-insensitively before matching, so a query
    /// of "copy on select" finds an entry with synonyms
    /// `"terminal.copyOnSelect copy on selection clipboard"`.
    public let synonyms: String

    /// Dotted cmux.json path used as the scroll/highlight anchor.
    ///
    /// When `nil`, ``SettingsSearchIndex`` falls back to dotted tokens
    /// in ``synonyms`` for existing entries. Set this when localized
    /// synonyms contain additional dotted search terms that should not
    /// become row anchors.
    public let anchorPath: String?

    public init(
        section: SettingsSectionID,
        id: String,
        title: String,
        detailText: String = "",
        paths: [String] = [],
        synonyms: String,
        anchorPath: String? = nil
    ) {
        self.section = section
        self.id = id
        self.title = title
        self.detailText = detailText
        self.paths = paths
        self.synonyms = synonyms
        self.anchorPath = anchorPath
    }
}
