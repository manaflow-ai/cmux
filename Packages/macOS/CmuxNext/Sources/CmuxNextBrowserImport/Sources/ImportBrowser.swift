import Foundation

/// The browser engine family a source belongs to, which decides the file
/// formats its profiles use.
public enum BrowserFamily: String, Sendable, Codable {
    case chromium
    case firefox
    case safari
    /// WebKit browsers with their own private formats (Orion, DuckDuckGo):
    /// detected so the user sees them, but nothing reads their data.
    case webkit
}

/// A browser cmux can import from. Paths are relative to the user's home
/// directory, so tests point the detector at a fixture home. Raw values are
/// stored in the import store; never rename one.
///
/// Browsers that share one data folder are one source: Chrome's channels
/// each have their own folder, but Firefox Developer Edition and Nightly
/// keep their profiles in Firefox's `profiles.ini`, and ungoogled-chromium
/// is Chromium (same bundle id and folder).
public enum ImportBrowser: String, Sendable, Codable, CaseIterable, Identifiable {
    case chrome, chromeBeta, chromeDev, chromeCanary, chromium
    case arc, dia, comet
    case brave, braveBeta, braveNightly
    case edge, edgeBeta, edgeDev, edgeCanary
    case vivaldi, opera, operaGX, helium, sidekick, yandex, thorium
    case safari, safariTechnologyPreview
    case firefox, zen, floorp, librewolf, waterfox, tor
    case orion, duckDuckGo

    public var id: String { rawValue }

    var entry: BrowserCatalogEntry { BrowserCatalog.entry(self) }

    /// Product names are not translated.
    public var displayName: String { entry.name }
    public var family: BrowserFamily { entry.family }
    /// Bundle identifiers, most common first (used to find the app and its icon).
    public var bundleIDs: [String] { entry.bundleIDs }

    /// The data directory, relative to home. For Chromium browsers this is
    /// the "user data dir" that holds `Local State` and the profile folders.
    public var dataDirectory: String { entry.dataDirectory }

    /// Chromium: the Keychain item ("<Name> Safe Storage") whose password
    /// encrypts the browser's cookies and passwords.
    public var safeStorageService: String? { entry.safeStorage }

    /// Whether cmux can read this browser's saved passwords. Yandex seals them
    /// with its own scheme, so its passwords show as unsupported (use its export).
    public var readsSavedPasswords: Bool { entry.readsPasswords && !refusesSessionData }

    /// Chromium browsers that keep one profile in the data folder itself
    /// (Opera), not in `Default` / `Profile N` subfolders.
    public var profileIsDataDirectory: Bool { entry.rootProfile }

    /// Tor Browser: cookies and history are never imported, because moving
    /// them out of Tor would link the user's Tor identity to cmux.
    public var refusesSessionData: Bool { self == .tor }

    /// Whether the store lists this browser's extensions (Chrome Web Store).
    public var sharesChromeWebStore: Bool { family == .chromium }

    /// Safari keeps cookies in its container, outside `dataDirectory`.
    public var safariCookieFile: String? {
        switch self {
        case .safari: "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
        case .safariTechnologyPreview: "Library/Containers/com.apple.SafariTechnologyPreview/Data/Library/Cookies/Cookies.binarycookies"
        default: nil
        }
    }
}
