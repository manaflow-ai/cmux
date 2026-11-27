public import CmuxNextBrowserImport

/// What the first-run import card (RFD 0125 D4) asks: which browser profile,
/// into which cmux profile, which kinds, and whether imported sign-ins keep
/// following the other browser. Pure value; the card draws it and the app
/// hands it to the existing importer (`OnboardingService.show(step: .importData…)`).
public struct FirstRunImportPlan: Equatable, Sendable {
    /// A cmux profile the person can import into.
    public struct Profile: Equatable, Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Where the data lands: a new cmux profile named after the source, or one the person has.
    public enum Destination: Equatable, Sendable {
        case newProfile
        case existing(Profile)
    }

    /// The rows the card lists, in order.
    public static let kindOrder: [ImportDataKind] = [.bookmarks, .history, .passwords, .cookies, .searchEngines, .extensions, .openTabs]
    /// D4's defaults: everything that makes the new browser feel like the old one is checked;
    /// extensions and open tabs, which change what runs and what is on screen, are not.
    public static let checkedByDefault: Set<ImportDataKind> = [.bookmarks, .history, .passwords, .cookies, .searchEngines]

    public var browser: ImportBrowser
    /// The source profile's name as the card shows it ("Chrome · Work", or "Safari").
    public var sourceProfile: String
    /// The cmux profiles the popup lists after New Profile.
    public var profiles: [Profile]
    public var destination: Destination
    public var kinds: Set<ImportDataKind>
    /// `browser.import.cookieSync` (absent is on).
    public var mirrorOn: Bool

    /// The defaults: D4's checked kinds, the first existing cmux profile (else a new one).
    public init(browser: ImportBrowser, sourceProfile: String, profiles: [Profile], mirrorOn: Bool) {
        self.browser = browser
        self.sourceProfile = sourceProfile
        self.profiles = profiles
        self.destination = profiles.first.map(Destination.existing) ?? .newProfile
        self.kinds = Self.checkedByDefault
        self.mirrorOn = mirrorOn
    }

    /// Whether the card shows the mirror line: cookie sync reads Chromium stores only.
    public var offersMirror: Bool { browser.family == .chromium }

    /// Whether Import overwrites the destination's cookies for the same sites, stated on the card.
    public var replacesCookies: Bool {
        guard kinds.contains(.cookies), case .existing = destination else { return false }
        return true
    }

    /// Whether imported sign-ins keep following the source after Import.
    public var mirrors: Bool { offersMirror && mirrorOn && kinds.contains(.cookies) }

    /// The import target the existing importer takes: an existing profile's id, nil for a new one.
    public var importTarget: String? {
        if case .existing(let profile) = destination { return profile.id }
        return nil
    }

    public mutating func toggle(_ kind: ImportDataKind) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
    }

    /// Picks the popup's row `index`: 0 is New Profile, then `profiles` in order.
    public mutating func selectDestination(at index: Int) {
        destination = index > 0 && index <= profiles.count ? .existing(profiles[index - 1]) : .newProfile
    }

    /// The popup row the destination sits on.
    public var destinationIndex: Int {
        guard case .existing(let profile) = destination, let i = profiles.firstIndex(of: profile) else { return 0 }
        return i + 1
    }

    /// Import is offered once something is checked.
    public var canImport: Bool { !kinds.isEmpty }
}
