import Foundation

/// The rendering-engine family of a detected browser, which determines how its
/// on-disk cookie and history databases are laid out and decoded.
public enum BrowserImportEngineFamily: String, Hashable, Sendable {
    /// Chromium-based browsers (Chrome, Edge, Brave, Arc, and others) that store
    /// data in SQLite `Cookies`/`History` databases.
    case chromium
    /// Firefox-based browsers (Firefox, Zen, Floorp, Waterfox) that store data in
    /// `cookies.sqlite`/`places.sqlite` and a `profiles.ini` index.
    case firefox
    /// WebKit-based browsers (Safari, Orion, Ladybird) that store data in
    /// `History.db` and `Cookies.binarycookies`.
    case webkit
}
