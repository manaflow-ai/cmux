public import CmuxNextPages
public import Foundation

/// The change a click on the Updated card's list asks the What's New page to show (Leo,
/// 2026-11-08: "maybe just bring them to the section in what's new aka bringing that tab up").
/// The page scrolls to the row titled `entry`, else to the newest day's `area` section.
/// `nonce` differs on every click, so clicking the same row again scrolls an open tab again.
public nonisolated struct ChangelogFocus: Sendable, Equatable {
    public var area: String?
    public var entry: String?
    public var nonce: String

    /// Nil when neither `area` nor `entry` is given (the card's own "What's New" link).
    public init?(area: String?, entry: String?, nonce: String? = nil) {
        let area = area.flatMap { $0.isEmpty ? nil : $0 }, entry = entry.flatMap { $0.isEmpty ? nil : $0 }
        guard area != nil || entry != nil else { return nil }
        self.area = area
        self.entry = entry
        self.nonce = nonce ?? String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
    }
}

extension WhatsNewDesign {
    /// The What's New page's route in this design, `#/?design=<d>&from=<from>&to=<to>&area=<a>&entry=<t>&n=<nonce>`:
    /// `design` only off the default sheet, the span only with `to`, the focus only when given;
    /// nil when none applies.
    public func changelogRoute(from: String?, to: String?, focus: ChangelogFocus? = nil) -> String? {
        let design = self, span = to.flatMap { $0.isEmpty ? nil : $0 }
        guard span != nil || design != .sheet || focus != nil else { return nil }
        var query = URLComponents()
        query.queryItems = [design == .sheet ? nil : URLQueryItem(name: "design", value: design.rawValue),
                            span.flatMap { _ in from.flatMap { $0.isEmpty ? nil : URLQueryItem(name: "from", value: $0) } },
                            span.map { URLQueryItem(name: "to", value: $0) },
                            focus?.area.map { URLQueryItem(name: "area", value: $0) },
                            focus?.entry.map { URLQueryItem(name: "entry", value: $0) },
                            focus.map { URLQueryItem(name: "n", value: $0.nonce) }].compactMap { $0 }
        // URLSearchParams reads `+` as a space; a version may carry build metadata (`1.2.3+abc`),
        // and a title may carry a `+` of its own.
        return "#/?" + (query.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }
}
