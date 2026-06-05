import CmuxSettings
import Foundation

/// A single user-curated search entry surfaced by ``SettingsSearchIndex``.
///
/// Each entry pairs a navigable ``SettingsSectionID`` with a stable id,
/// a localized title, and a search synonym string mined from how users
/// actually refer to the setting (the legacy `SettingsSearchAliasIndex`
/// table is the source).
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

    /// Space-separated synonym tokens. The search index folds these
    /// case- and diacritic-insensitively before matching, so a query
    /// of "copy on select" finds an entry with synonyms
    /// `"terminal.copyOnSelect copy on selection clipboard"`.
    public let synonyms: String

    public init(
        section: SettingsSectionID,
        id: String,
        title: String,
        synonyms: String
    ) {
        self.section = section
        self.id = id
        self.title = title
        self.synonyms = synonyms
    }
}
