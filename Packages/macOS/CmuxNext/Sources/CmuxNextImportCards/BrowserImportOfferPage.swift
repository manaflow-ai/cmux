/// The facts about one browser tab's finished page that decide the offer.
public struct BrowserImportOfferPage: Equatable, Sendable {
    /// The person's own profile: not incognito, not agent-driven, not the agent profile.
    public var isPersonal: Bool
    /// A page notice (a Chromium fallback, a moved tab) already sits at the bottom; window toasts lift the card instead.
    public var showsOtherNotice: Bool
    /// The page asks the person to sign in (a password or user name field): only such a page offers the
    /// banner (Lawrence 2026-11-09, shown less often).
    public var asksSignIn: Bool
    /// The tab's cmux browser profile (its wire id): the card shows at most once on each
    /// (``BrowserImportOfferState/shownOn``). Nil: not named (a test), never held back by it.
    public var profile: String?

    /// - Parameters:
    ///   - isPersonal: The tab is the person's own (not incognito, not an agent's).
    ///   - showsOtherNotice: Another notice already sits at the bottom of the page.
    ///   - asksSignIn: The page shows a sign-in form. True by default for callers that already checked it
    ///     (Show Import Cookies Banner, the debug verb).
    ///   - profile: The tab's cmux browser profile.
    public init(isPersonal: Bool, showsOtherNotice: Bool, asksSignIn: Bool = true, profile: String? = nil) {
        self.isPersonal = isPersonal
        self.showsOtherNotice = showsOtherNotice
        self.asksSignIn = asksSignIn
        self.profile = profile
    }
}
