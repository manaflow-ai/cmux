/// The facts about one browser tab's finished page that decide the offer.
public struct BrowserImportOfferPage: Equatable, Sendable {
    /// The person's own profile: not incognito, not agent-driven, not the agent profile.
    public var isPersonal: Bool
    /// A page notice (a Chromium fallback, a moved tab) already sits at the bottom; window toasts lift the card instead.
    public var showsOtherNotice: Bool

    /// - Parameters:
    ///   - isPersonal: The tab is the person's own (not incognito, not an agent's).
    ///   - showsOtherNotice: Another notice already sits at the bottom of the page.
    public init(isPersonal: Bool, showsOtherNotice: Bool) {
        self.isPersonal = isPersonal
        self.showsOtherNotice = showsOtherNotice
    }
}
