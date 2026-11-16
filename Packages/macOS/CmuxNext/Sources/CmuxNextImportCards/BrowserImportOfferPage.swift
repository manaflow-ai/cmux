/// The facts about one browser tab's finished page that decide the offer.
public struct BrowserImportOfferPage: Equatable, Sendable {
    /// The person's own profile: not incognito, not agent-driven, not the agent profile.
    public var isPersonal: Bool
    /// A page notice (a Chromium fallback, a moved tab) already sits at the bottom; window toasts lift the card instead.
    public var showsOtherNotice: Bool
    /// The page asks the person to sign in (a password or user name field): only such a page offers the
    /// banner (Lawrence 2026-11-09, shown less often).
    public var asksSignIn: Bool

    /// - Parameters:
    ///   - isPersonal: The tab is the person's own (not incognito, not an agent's).
    ///   - showsOtherNotice: Another notice already sits at the bottom of the page.
    ///   - asksSignIn: The page shows a sign-in form. True by default for callers that already checked it
    ///     (Show Import Cookies Banner, the debug verb).
    public init(isPersonal: Bool, showsOtherNotice: Bool, asksSignIn: Bool = true) {
        self.isPersonal = isPersonal
        self.showsOtherNotice = showsOtherNotice
        self.asksSignIn = asksSignIn
    }
}
