public import Foundation

/// A folder's name as Finder shows it, without reading inside the person's standard folders.
///
/// `FileManager.displayName(atPath:)` asks Launch Services, which looks inside the folder (its
/// `.localized` marker) to localize it. For Desktop, Documents and Downloads that look is a read of
/// a protected folder by the app itself, so opening a Files pane, or only showing the sidebar's
/// Favorites, asked macOS for Downloads in the app's name even when the listing itself is read
/// elsewhere (docs/cmux-files-host.md, "The Files pane"). The standard folders of `home` take their
/// name from the system's own table (`SystemFolderLocalizations`, the strings Launch Services
/// reads) instead; every other folder still asks Launch Services.
public struct FolderDisplayName: Sendable {
    /// The folders of a home that macOS names from its system table.
    static let standardFolders: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
    ]

    private let home: String
    private let systemNames: @Sendable (String) -> String

    /// - Parameters:
    ///   - home: The person's home folder.
    ///   - systemNames: The localized name of a standard folder (tests pass a fixed table).
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                systemNames: (@Sendable (String) -> String)? = nil) {
        self.home = home.standardizedFileURL.path
        self.systemNames = systemNames ?? { Self.systemName($0) }
    }

    /// The name of `folder`: a standard folder of the home by the system's table, any other by
    /// Launch Services.
    public func name(of folder: URL) -> String {
        let path = folder.standardizedFileURL
        let name = path.lastPathComponent
        if path.deletingLastPathComponent().path == home, Self.standardFolders.contains(name) {
            return systemNames(name)
        }
        return FileManager.default.displayName(atPath: path.path)
    }

    /// The system's localized name of a standard folder, in the person's language; the English
    /// name when the table has none.
    private static func systemName(_ name: String) -> String {
        let table = Bundle(path: "/System/Library/CoreServices/SystemFolderLocalizations")
        return table?.localizedString(forKey: name, value: name, table: "SystemFolderLocalizations") ?? name
    }
}
