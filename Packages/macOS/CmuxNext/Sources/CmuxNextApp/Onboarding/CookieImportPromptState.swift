import CmuxNextBrowser
import Foundation

/// What the cookie import card remembers on this Mac: Don't Show Again,
/// a finished cookie import (it never shows after one), and the Not Now
/// snooze. A small JSON value in the app's user defaults, like the tip
/// card's state; not a setting.
struct CookieImportPromptState: Codable, Equatable {
    var neverShow = false
    var imported = false
    /// Not Now (or an Import Cookies click that brought no cookie) hides
    /// the card until then.
    var snoozedUntil: Date?

    static let defaultsKey = "cookieImportPrompt.state"
    /// How long Not Now hides the card.
    static let snooze: TimeInterval = 7 * 24 * 60 * 60

    static func load(from defaults: UserDefaults) -> CookieImportPromptState {
        guard let data = defaults.data(forKey: defaultsKey) else { return CookieImportPromptState() }
        return (try? JSONDecoder().decode(CookieImportPromptState.self, from: data)) ?? CookieImportPromptState()
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Whether a page that just finished loading may show the card: a web
    /// page in the person's own Chromium profile (never incognito, never an
    /// agent's tab), with no other notice on it, while the card is neither
    /// turned off, done nor snoozed.
    func offers(_ page: CookieImportPage, now: Date) -> Bool {
        guard !neverShow, !imported, snoozedUntil.map({ now >= $0 }) ?? true else { return false }
        guard ["http", "https"].contains(page.url.scheme?.lowercased() ?? "") else { return false }
        return page.isChromium && page.isPersonal && !page.showsOtherNotice
    }

    /// The person's answer on the card.
    mutating func answer(_ choice: BrowserCookieImportChoice, now: Date) {
        switch choice {
        case .never: neverShow = true
        // Import Cookies snoozes too: a cancelled import must not bring the card straight back.
        case .notNow, .importCookies: snoozedUntil = now.addingTimeInterval(Self.snooze)
        }
    }
}

/// The facts about one finished page load that decide the card.
struct CookieImportPage: Equatable {
    var url: URL
    var isChromium: Bool
    /// The person's own profile: not incognito, not agent-driven, not the agent profile.
    var isPersonal: Bool
    /// Another notice (a Chromium fallback, a moved tab) already sits at the bottom of the page.
    var showsOtherNotice: Bool
}
