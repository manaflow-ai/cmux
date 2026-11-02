public import CmuxNextBrowserImport
public import Foundation

/// What the Import Cookies banner remembers outside cmux.json: that cookies
/// came over (from it, File > Import from Browser or a suggestion card), which
/// ends it for good. A small JSON value in the app's user defaults, whose
/// domain is the bundle id, so each channel (release, nightly, each tagged dev
/// build) remembers on its own. The person's dismissal is not here: Don't Show
/// Again writes `browser.import.cookieBanner: false` (``BrowserCookieBannerSetting``),
/// so Settings shows it and can turn it back on.
public struct BrowserImportOfferState: Codable, Equatable, Sendable {
    /// Cookies came over: the banner is done.
    public var imported = false

    /// A fresh Mac: nothing imported yet.
    public init() {}

    /// A new key: the earlier card (bookmarks, history and passwords, `browserImportOffer.state`)
    /// was another offer, and its Not Now does not hide this one.
    public static let defaultsKey = "browserImportOffer.cookies.state"

    /// The saved record in `defaults`; a fresh one when absent or unreadable.
    public static func load(from defaults: UserDefaults) -> BrowserImportOfferState {
        guard let data = defaults.data(forKey: defaultsKey) else { return BrowserImportOfferState() }
        return (try? JSONDecoder().decode(BrowserImportOfferState.self, from: data)) ?? BrowserImportOfferState()
    }

    /// Saves the record in `defaults`.
    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Whether a browser tab's page may show the banner: the person's own
    /// tab (never incognito, never an agent's), with no other notice on it,
    /// until cookies came over.
    public func offers(_ page: BrowserImportOfferPage) -> Bool {
        !imported && page.isPersonal && !page.showsOtherNotice
    }

    /// An import finished: once cookies came over, the banner never shows again.
    /// Bookmarks or history alone keep it.
    public mutating func recordImport(_ counts: ImportCounts) {
        if counts.cookies > 0 { imported = true }
    }
}
