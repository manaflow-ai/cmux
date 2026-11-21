public import CmuxNextBrowserImport
public import Foundation

/// What the Import Cookies banner remembers outside cmux.json: that cookies
/// came over (from it, File > Import from Browser or a suggestion card), which
/// ends it for good, and a Not Now, which keeps it away for a week
/// (``notNowInterval``). A small JSON value in the app's user defaults, whose
/// domain is the bundle id, so each channel (release, nightly, each tagged dev
/// build) remembers on its own. The person's dismissal is not here: Don't Show
/// Again writes `browser.import.cookieBanner: false` (``BrowserCookieBannerSetting``),
/// so Settings shows it and can turn it back on.
public struct BrowserImportOfferState: Codable, Equatable, Sendable {
    /// Cookies came over: the banner is done.
    public var imported = false
    /// The person clicked Not Now: no card until then, across relaunches (David Beyer, Nov 20 call: no
    /// nagging; a nightly relaunches each day for its update). Nil: never answered Not Now.
    public var notNowUntil: Date?

    /// How long a Not Now keeps the card away.
    public static let notNowInterval: TimeInterval = 7 * 24 * 60 * 60

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
    /// tab (never incognito, never an agent's) on a page that asks to sign in,
    /// with no other notice on it, until cookies came over, and not in the week after a Not Now.
    /// - Parameter now: The time asked about (tests pass their own).
    public func offers(_ page: BrowserImportOfferPage, now: Date = Date()) -> Bool {
        !imported && !waitsAfterNotNow(now: now) && page.isPersonal && !page.showsOtherNotice && page.asksSignIn
    }

    /// Whether a Not Now still keeps the card away at `now`.
    public func waitsAfterNotNow(now: Date = Date()) -> Bool {
        notNowUntil.map { now < $0 } ?? false
    }

    /// The person clicked Not Now at `now`: the card stays away for ``notNowInterval``.
    public mutating func recordNotNow(at now: Date = Date()) {
        notNowUntil = now.addingTimeInterval(Self.notNowInterval)
    }

    /// An import finished: once cookies came over, the banner never shows again.
    /// Bookmarks or history alone keep it.
    public mutating func recordImport(_ counts: ImportCounts) {
        if counts.cookies > 0 { imported = true }
    }
}
