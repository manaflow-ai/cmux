public import Foundation

/// When a ready web update may reload the open pages (plans/cmux-next/web-ota.md, "The safe
/// point"). The swap never loses or disturbs what someone is doing: it goes at once while no page
/// shows; otherwise it waits until the app has nothing modal open, until nobody has touched the
/// keyboard, pointer or trackpad for ``quietInput`` while cmux is in the front (``grace`` after it
/// leaves it), and until every served page answers that a reload keeps all it holds (a draft, its
/// chips, its place, its selection, no open menu, nothing being sent). Any other answer, or none in
/// ``answerWithin``, waits ``retry`` and asks again. Pure decisions; `WebUpdates` reads the app.
nonisolated public struct WebSwapGate: Sendable {
    public init() {}

    /// No input for this long while cmux is in the front.
    public static let quietInput: Duration = .seconds(30)
    /// The wait once cmux leaves the front.
    public static let grace: Duration = .seconds(3)
    /// The next look after the app or a page was busy.
    public static let retry: Duration = .seconds(15)
    /// How long a page has to answer.
    public static let answerWithin: Duration = .seconds(1)

    public enum Decision: Equatable, Sendable {
        /// Swap now.
        case swap
        /// Ask the served pages, then ``pages(_:)``.
        case askPages
        /// Look again after `after`; `reason` names what held it (`updates.web.status`).
        case later(after: Duration, reason: String)
    }

    /// The app's half. `pagesShown`: a served page shows a document. `active`: cmux is in the
    /// front. `idle`: seconds since the last input event. `blocked`: what modal the app has open (a
    /// sheet, a modal window, a menu being tracked), nil when none. `away`: seconds since cmux left
    /// the front (infinite when it never was there).
    public static func app(
        pagesShown: Bool, active: Bool, idle: TimeInterval, blocked: String?, away: TimeInterval = .infinity
    ) -> Decision {
        guard pagesShown else { return .swap }
        if let blocked { return .later(after: retry, reason: blocked) }
        if !active {
            let left = seconds(grace) - away
            // Just switched away (and maybe back): the grace runs out first.
            if left > 0 { return .later(after: .milliseconds(Int(left * 1000) + 1), reason: "grace") }
        } else {
            let quiet = seconds(quietInput)
            // Due when the quiet period ends, at least a second out (input may have just landed).
            if idle < quiet { return .later(after: .milliseconds(Int(max(1, quiet - idle) * 1000)), reason: "input") }
        }
        return .askPages
    }

    /// The pages' half: each page's answer, nil when a reload keeps all it holds, else why not
    /// (`page.no-answer` for a page that did not answer in time).
    public static func pages(_ answers: [String?]) -> Decision {
        if let busy = answers.lazy.compactMap({ $0 }).first { return .later(after: retry, reason: busy) }
        return .swap
    }

    /// `duration` in seconds.
    public static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
