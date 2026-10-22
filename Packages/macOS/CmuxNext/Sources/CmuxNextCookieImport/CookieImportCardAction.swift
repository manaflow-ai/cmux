/// A button of the cookie import card (also a tool card's action id).
enum CookieImportCardAction: String, Sendable, Equatable {
    case allow, deny, showRequester, remove, showAll, showSites, dismiss
}
