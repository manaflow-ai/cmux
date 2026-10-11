import CmuxNextBrowserImport
import Foundation

/// What the browser-data import offer remembers: Not Now, and an import
/// that brought data over. Both end it for good. A small JSON value in the
/// app's user defaults, whose domain is the bundle id, so each channel
/// (release, nightly, each tagged dev build) remembers on its own. Not a
/// setting.
struct BrowserImportOfferState: Codable, Equatable {
    var dismissed = false
    var imported = false

    static let defaultsKey = "browserImportOffer.state"

    static func load(from defaults: UserDefaults) -> BrowserImportOfferState {
        guard let data = defaults.data(forKey: defaultsKey) else { return BrowserImportOfferState() }
        return (try? JSONDecoder().decode(BrowserImportOfferState.self, from: data)) ?? BrowserImportOfferState()
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Whether a browser tab's page may show the offer: the person's own
    /// tab (never incognito, never an agent's), with no other notice on it,
    /// while the offer was neither dismissed nor done.
    func offers(_ page: BrowserImportOfferPage) -> Bool {
        !dismissed && !imported && page.isPersonal && !page.showsOtherNotice
    }

    /// An import finished (this offer's, or File > Import from Browser):
    /// once data came over, the offer never shows again.
    mutating func recordImport(_ counts: ImportCounts) {
        if counts.total > 0 { imported = true }
    }
}

/// The facts about one browser tab's finished page that decide the offer.
struct BrowserImportOfferPage: Equatable {
    /// The person's own profile: not incognito, not agent-driven, not the agent profile.
    var isPersonal: Bool
    /// A page notice (a Chromium fallback, a moved tab) already sits at the bottom; window toasts lift the card instead.
    var showsOtherNotice: Bool
}
