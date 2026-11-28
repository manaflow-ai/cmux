import Foundation

/// How a source lists its profiles.
public enum ProfileDiscovery: String, Sendable, Codable {
    /// Chromium: `Local State` (`profile.info_cache`), else `Default` / `Profile N` folders.
    case chromiumLocalState
    /// One profile that is the data folder itself (Opera).
    case dataDirectory
    /// Firefox: `profiles.ini`, else folders with a `prefs.js`.
    case firefoxProfilesIni
    /// One store for the whole app (Safari, private WebKit stores).
    case single
}

/// The file format a source keeps its bookmarks in, which picks the reader.
public enum BookmarksFormat: String, Sendable, Codable {
    /// Chromium `Bookmarks` JSON (bar, other, mobile).
    case chromiumJSON
    /// Firefox `places.sqlite`, read from a private copy (WAL included).
    case firefoxPlaces
    /// Safari `Bookmarks.plist` (needs Full Disk Access).
    case safariPlist
    /// Arc `StorableSidebar.json`: spaces, pinned tabs and folders, Favorites.
    case arcSidebar
    /// No readable store; the browser's own Netscape HTML export is the path.
    case htmlExport
    /// No readable store and no known export.
    case noStore = "none"
}

/// Defaults shared by every row of one engine family.
public struct EngineDefaults: Sendable, Codable, Equatable {
    public var profiles: ProfileDiscovery
    public var bookmarks: BookmarksFormat
    public var files: BrowserDataFiles
}
