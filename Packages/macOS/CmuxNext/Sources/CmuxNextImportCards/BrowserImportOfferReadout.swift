public import CmuxNextSettings
import Foundation

/// `browser.import_offer` (every build, read-only): where the Chrome import card stands, so a NIGHTLY can be
/// read back without a DEBUG build or a screenshot (window screenshots mask the browser area). It changes
/// nothing; `debug.browser_import_offer` (DEBUG) drives the card and returns this same readout.
/// - `banner_on`, `offered`, `imported`: the settings and the import record allow it.
/// - `shown_this_launch`; `shown_on_profiles`: the profiles it already showed on (it never offers itself
///   there again); `not_now_until`: ISO 8601, or null.
/// - `cards`: each browser tab whose chrome holds a card: `showing` (on screen), `waits_for_focus`
///   (its tab lost the keyboard), `seen` (it was on screen with the keyboard there: losing it closes the card).
public struct BrowserImportOfferReadout {
    public init() {}
    /// A card a browser tab's chrome holds.
    public struct Card: Equatable, Sendable {
        public var showing: Bool
        public var waitsForFocus: Bool
        public var seen: Bool

        public init(showing: Bool, waitsForFocus: Bool, seen: Bool) {
            self.showing = showing
            self.waitsForFocus = waitsForFocus
            self.seen = seen
        }
    }

    /// - Parameters:
    ///   - cards: The cards held, by browser tab key.
    ///   - browsers: The browsers it could import from, most used first; nil before they were found.
    public static func json(state: BrowserImportOfferState, bannerOn: Bool, offered: Bool, shownThisLaunch: Bool,
                            cards: [String: Card], browsers: [String]?) -> JSONValue {
        let showing = cards.filter(\.value.showing).map(\.key).sorted()
        return .object([
            "banner_on": .bool(bannerOn), "dismissed": .bool(!bannerOn), "offered": .bool(offered),
            "showing": .bool(!showing.isEmpty), "shown_on": .array(showing.map(JSONValue.string)),
            "imported": .bool(state.imported), "shown_this_launch": .bool(shownThisLaunch),
            "shown_on_profiles": .array((state.shownOn ?? []).sorted().map(JSONValue.string)),
            "not_now_until": state.notNowUntil.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "cards": .object(cards.mapValues { card in
                .object(["showing": .bool(card.showing), "waits_for_focus": .bool(card.waitsForFocus), "seen": .bool(card.seen)])
            }),
            "browsers": browsers.map { .array($0.map(JSONValue.string)) } ?? .null,
        ])
    }
}
