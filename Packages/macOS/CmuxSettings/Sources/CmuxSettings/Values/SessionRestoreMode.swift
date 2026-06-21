import Foundation

/// How cmux handles a previously saved session when it launches.
///
/// Stored under the catalog entry ``SessionCatalogSection/restoreMode``
/// (`session.restoreMode` in `~/.config/cmux/cmux.json`). The raw values are
/// the on-disk strings, so they must not be renamed without a migration.
public enum SessionRestoreMode: String, CaseIterable, Sendable, SettingCodable {
    /// Silently restore the previous windows, tabs, and panes on launch
    /// (the historical cmux behavior).
    case always

    /// Prompt before restoring; the user chooses Restore or Start Fresh.
    /// This is the default.
    case ask

    /// Never restore automatically; start with a fresh window. The previous
    /// session stays reopenable from File ▸ Reopen Previous Session.
    case never
}
