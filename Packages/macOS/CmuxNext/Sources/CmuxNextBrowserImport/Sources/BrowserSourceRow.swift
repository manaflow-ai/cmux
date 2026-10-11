import Foundation

/// What kind of app a catalog entry is. Import pickers list only
/// browsers and enterprise browsers; the rest stay in the catalog with
/// their verdict.
public enum BrowserSourceKind: String, Sendable, Codable {
    case browser
    case enterpriseBrowser
    /// An app with an in-app browser (ChatGPT): passwords and history, no bookmarks.
    case appWithEmbeddedBrowser
    case appContainer
    case devTool
    case antiDetect
    case nonBrowserApp
    /// A browser with no readable local store (discontinued, demo, unknown layout).
    case noLocalStore

    /// Whether bookmark pickers list sources of this kind.
    public var listsForBookmarks: Bool { self == .browser || self == .enterpriseBrowser }
}

/// One browser of the registry (`browser-sources.json`). Paths are relative
/// to the user's home. Fields left out take the engine's defaults.
public struct BrowserSourceRow: Sendable, Codable, Equatable, Identifiable {
    /// Stable id, stored by imports (`ImportBrowser.rawValue`); never rename one.
    public var id: String
    /// The product name (not translated).
    public var name: String
    public var vendor: String
    public var kind: BrowserSourceKind
    public var engine: BrowserFamily
    /// Most common first; used to find the app and its icon.
    public var bundleIDs: [String]
    /// App names (without `.app`) that also find the app, for rows whose
    /// bundle id was not checked on a real install.
    public var appNames: [String]?
    /// False when the bundle id or data folder was inferred, not seen on a
    /// real install or in the vendor's docs.
    public var verified: Bool?
    /// Data folders, most likely first (the first one that exists is used).
    public var dataDirectories: [String]
    public var profiles: ProfileDiscovery?
    public var bookmarks: BookmarksFormat?
    public var files: BrowserDataFiles?
    /// Arc: the sidebar file, relative to home.
    public var sidebarFile: String?
    /// Safari: the cookie file in its container, relative to home.
    public var cookieFile: String?
    public var safeStorage: SafeStorageItem?
    /// Kinds the source keeps in a format cmux cannot read (Yandex
    /// passwords: "Ya Passman Data" with an extra encryption layer).
    public var unsupportedKinds: [String]?
    /// Tor Browser: cookies and history stay in Tor.
    public var refusesSessionData: Bool?
    public var evidence: [BrowserSourceEvidence]
}

/// A desktop app that is not a browser but was checked for local bookmarks
/// (ChatGPT, Perplexity): listed with the verdict, never detected.
public struct NonBrowserApp: Sendable, Codable, Equatable {
    public var name: String
    public var bundleIDs: [String]
    public var kind: BrowserSourceKind
    public var verdict: String
    public var evidence: [BrowserSourceEvidence]
}
