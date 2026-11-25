public import CmuxNextBrowserImport
import CmuxNextCompat
public import Foundation

/// What the Import Cookies banner remembers outside cmux.json: that cookies
/// came over (from it, File > Import from Browser or a suggestion card), which
/// ends it for good, and a Not Now, which keeps it away for 30 days
/// (``notNowInterval``), and the profiles it already showed on, each of which it never asks again by
/// itself (Leo 2026-11-22: "the whole import sign in to google chrome fires too often"). A small JSON value in the app's user defaults, whose
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
    /// The cmux browser profiles (``BrowserImportOfferPage/profile``) the card already showed on. It shows at
    /// most once on each, answered or not: never again on a later launch, tab or focus change (Leo 2026-11-22:
    /// "it just needs a better lifecycle"). Show Import Cookies Banner asks again. Nil: an older record.
    public var shownOn: Set<String>?

    /// How long a Not Now keeps the card away: 30 days (Leo 2026-11-22: "the import from chrome apperaing on
    /// every single focus and never expiring"). A week came back too soon for a card the person already
    /// declined; a month is long enough not to nag, short enough that a new Mac or a newly used browser still
    /// gets one more offer. Never for Chrome ends it for good (`browser.import.cookieBanner`).
    public static let notNowInterval: TimeInterval = 30 * 24 * 60 * 60

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
    /// with no other notice on it, until cookies came over, not in the 30 days after a Not Now, and never on a
    /// profile it already showed on.
    /// - Parameter now: The time asked about (tests pass their own).
    public func offers(_ page: BrowserImportOfferPage, now: Date = Date()) -> Bool {
        !imported && !waitsAfterNotNow(now: now) && page.isPersonal && !page.showsOtherNotice && page.asksSignIn
            && !hasShown(on: page.profile)
    }

    /// Whether the card already showed on `profile` (nil: a page with no profile named, never held back).
    public func hasShown(on profile: String?) -> Bool {
        profile.map { shownOn?.contains($0) == true } ?? false
    }

    /// The card showed on `profile`: it never offers itself there again.
    public mutating func recordShown(on profile: String?) {
        guard let profile else { return }
        shownOn = (shownOn ?? []).union([profile])
    }

    /// Show Import Cookies Banner: an earlier Not Now or showing no longer holds the card back.
    public mutating func askAgain() {
        notNowUntil = nil
        shownOn = nil
    }

    /// Whether this launch offers the card by itself: a normal launch, or one forced
    /// (`CMUX_NEXT_BROWSER_IMPORT_OFFER=1`). Never a launch that does not activate (a test), and never a
    /// `cmux app try` copy: each try is a new app with fresh defaults, so it would ask again on every try
    /// (Leo 2026-11-22: "the whole import sign in to google chrome fires too often").
    public static func launchOffers(noActivate: Bool?, bundleID: String?, forced: Bool) -> Bool {
        forced || (noActivate == false && !OtherAppContainers.isSideInstance(bundleID: bundleID))
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
