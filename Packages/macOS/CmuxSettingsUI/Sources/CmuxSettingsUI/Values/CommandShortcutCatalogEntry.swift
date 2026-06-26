import Foundation

/// One Command Palette command that the **Custom Commands** keyboard-shortcut
/// section can bind a shortcut to.
///
/// The host app owns the live command catalog (titles, subtitles, and search
/// keywords are derived from the same contributions that drive the Command
/// Palette), so this Foundation-only value type is the bridge the package uses
/// to render the command picker and resolve a bound command id back to a
/// human-readable title. The host supplies these through
/// ``SettingsHostActions/commandShortcutCatalog()`` and ranks them for a query
/// through ``SettingsHostActions/searchCommandShortcutCatalog(query:limit:)``,
/// reusing the Command Palette's own ranking engine.
public struct CommandShortcutCatalogEntry: Sendable, Equatable, Hashable, Identifiable {
    /// Stable command identifier (e.g. `palette.openFolderInVSCode`). This is
    /// the key written under `shortcuts.commands` in cmux.json.
    public let commandId: String
    /// Display title, matching the command's Command Palette title.
    public let title: String
    /// Secondary descriptor (e.g. `Workspace`, `Browser • Example`).
    public let subtitle: String
    /// Additional search keywords the host's matcher considers.
    public let keywords: [String]

    /// `Identifiable` conformance — the stable command id.
    public var id: String { commandId }

    /// Creates a catalog entry for one bindable Command Palette command.
    public init(commandId: String, title: String, subtitle: String, keywords: [String] = []) {
        self.commandId = commandId
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
    }
}
