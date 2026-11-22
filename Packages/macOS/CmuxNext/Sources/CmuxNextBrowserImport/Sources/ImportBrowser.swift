public import Foundation

/// The browser engine family a source belongs to, which decides the file
/// formats its profiles use.
public enum BrowserFamily: String, Sendable, Codable, CaseIterable {
    case chromium
    /// Gecko (Firefox and its forks).
    case firefox
    case safari
    /// WebKit browsers with their own private formats (Orion, DuckDuckGo):
    /// detected so the user sees them; their own HTML export is the path.
    case webkit
    /// Any other engine (Electron or custom stores): detected and listed
    /// like `webkit`.
    case other

    /// Whether this family keeps data in a private store cmux does not read.
    public var isPrivateStore: Bool { self == .webkit || self == .other }
}

/// A browser cmux can import from: one row of ``BrowserSourceRegistry``
/// (`browser-sources.json`). Raw values are stored in the import store;
/// never rename one. Paths are relative to the user's home directory, so
/// tests point the detector at a fixture home.
///
/// Browsers that share one data folder are one source: Chrome's channels
/// each have their own folder, but Firefox Developer Edition and Nightly
/// keep their profiles in Firefox's `profiles.ini`, and ungoogled-chromium
/// is Chromium (same bundle id and folder).
public struct ImportBrowser: RawRepresentable, Sendable, Hashable, Codable, Identifiable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
    public var description: String { rawValue }

    /// Every browser of the registry, in registry order.
    public static var allCases: [ImportBrowser] { BrowserSourceRegistry.shared.browsers.map { ImportBrowser(rawValue: $0.id) } }

    /// This browser's registry row; nil for an id an older build stored
    /// that the registry no longer has.
    public var row: BrowserSourceRow? { BrowserSourceRegistry.shared.row(rawValue) }

    /// The row with engine defaults applied.
    public var source: ResolvedBrowserSource? { row.map(BrowserSourceRegistry.shared.resolved) }

    /// What kind of app this is; bookmark pickers list only browsers.
    public var kind: BrowserSourceKind { row?.kind ?? .noLocalStore }
    /// Whether bookmark pickers list this source (browsers and enterprise browsers).
    public var listsForBookmarks: Bool { kind.listsForBookmarks }
    /// App names that also find an app whose bundle id is not verified.
    public var appNames: [String] { row?.appNames ?? [] }

    /// Product names are not translated.
    public var displayName: String { row?.name ?? rawValue }
    public var family: BrowserFamily { row?.engine ?? .other }
    /// Bundle identifiers, most common first (used to find the app and its icon).
    public var bundleIDs: [String] { row?.bundleIDs ?? [] }

    /// The first data directory, relative to home. For Chromium browsers
    /// this is the "user data dir" that holds `Local State` and the profile
    /// folders. `ImportEnvironment.dataDirectory(_:)` picks the first of
    /// ``dataDirectories`` that exists.
    public var dataDirectory: String { dataDirectories.first ?? "Library/Application Support/\(rawValue)" }
    public var dataDirectories: [String] { row?.dataDirectories ?? [] }

    /// Chromium: the Keychain item ("<Name> Safe Storage") whose password
    /// encrypts the browser's cookies and passwords.
    public var safeStorageService: String? { row?.safeStorage?.service }

    /// Whether cmux can read this browser's saved passwords. Yandex seals them
    /// with its own scheme, so its passwords show as unsupported (use its export).
    public var readsSavedPasswords: Bool { !(row?.unsupportedKinds ?? []).contains(ImportDataKind.passwords.rawValue) && !refusesSessionData }

    /// Chromium browsers that keep one profile in the data folder itself
    /// (Opera), not in `Default` / `Profile N` subfolders.
    public var profileIsDataDirectory: Bool { source?.profiles == .dataDirectory }

    /// The reader for this browser's bookmarks.
    public var bookmarksFormat: BookmarksFormat { source?.bookmarks ?? .noStore }

    /// Tor Browser: cookies and history are never imported, because moving
    /// them out of Tor would link the user's Tor identity to cmux.
    public var refusesSessionData: Bool { row?.refusesSessionData ?? false }

    /// Whether the store lists this browser's extensions (Chrome Web Store).
    public var sharesChromeWebStore: Bool { family == .chromium }

    /// Safari keeps cookies in its container, outside `dataDirectory`.
    public var safariCookieFile: String? { row?.cookieFile }

    // Stored ids of the browsers earlier builds knew; code that names one
    // browser uses these. Every other browser exists only as a registry row.
    public static let chrome = ImportBrowser(rawValue: "chrome")
    public static let chromeBeta = ImportBrowser(rawValue: "chromeBeta")
    public static let chromeDev = ImportBrowser(rawValue: "chromeDev")
    public static let chromeCanary = ImportBrowser(rawValue: "chromeCanary")
    public static let chromium = ImportBrowser(rawValue: "chromium")
    public static let arc = ImportBrowser(rawValue: "arc")
    public static let dia = ImportBrowser(rawValue: "dia")
    public static let comet = ImportBrowser(rawValue: "comet")
    public static let brave = ImportBrowser(rawValue: "brave")
    public static let braveBeta = ImportBrowser(rawValue: "braveBeta")
    public static let braveNightly = ImportBrowser(rawValue: "braveNightly")
    public static let edge = ImportBrowser(rawValue: "edge")
    public static let edgeBeta = ImportBrowser(rawValue: "edgeBeta")
    public static let edgeDev = ImportBrowser(rawValue: "edgeDev")
    public static let edgeCanary = ImportBrowser(rawValue: "edgeCanary")
    public static let vivaldi = ImportBrowser(rawValue: "vivaldi")
    public static let opera = ImportBrowser(rawValue: "opera")
    public static let operaGX = ImportBrowser(rawValue: "operaGX")
    public static let helium = ImportBrowser(rawValue: "helium")
    public static let sidekick = ImportBrowser(rawValue: "sidekick")
    public static let yandex = ImportBrowser(rawValue: "yandex")
    public static let thorium = ImportBrowser(rawValue: "thorium")
    public static let safari = ImportBrowser(rawValue: "safari")
    public static let safariTechnologyPreview = ImportBrowser(rawValue: "safariTechnologyPreview")
    public static let firefox = ImportBrowser(rawValue: "firefox")
    public static let zen = ImportBrowser(rawValue: "zen")
    public static let floorp = ImportBrowser(rawValue: "floorp")
    public static let librewolf = ImportBrowser(rawValue: "librewolf")
    public static let waterfox = ImportBrowser(rawValue: "waterfox")
    public static let tor = ImportBrowser(rawValue: "tor")
    public static let orion = ImportBrowser(rawValue: "orion")
    public static let duckDuckGo = ImportBrowser(rawValue: "duckDuckGo")
}
