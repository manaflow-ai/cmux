public import Foundation

/// When a ready web update may reload an open page (plans/cmux-next/web-ota.md, "The safe
/// point"). The swap never loses or disturbs what someone is doing, and it goes page by page: a
/// page that is ready reloads while another still holds, since each page reads the update it loaded
/// with until it reloads (``WebBundleServedViews``). A page reloads once the app has nothing modal
/// open and has been behind other apps for ``grace`` (or is in the front), once nobody has touched
/// the keyboard, pointer or trackpad for ``quietInput`` if it is the page being typed into (only
/// ``quietInputCapped`` once the update has waited ``inputCap``), and once it answers that a reload
/// keeps all it holds (a draft, its chips, its place, its selection, no open menu, nothing being
/// sent). Any other answer, or none in ``answerWithin``, waits ``retry`` and asks again; a page's
/// own answer is never overridden. Pure decisions; `WebUpdates` reads the app.
nonisolated public struct WebSwapGate: Sendable {
    public init() {}

    /// No input for this long, for the page that has the keyboard.
    public static let quietInput: Duration = .seconds(30)
    /// After the update waited ``inputCap``, the page that has the keyboard needs only this quiet.
    public static let quietInputCapped: Duration = .seconds(3)
    /// How long the page being typed into may keep an update waiting on input alone.
    public static let inputCap: Duration = .seconds(600)
    /// The wait once cmux leaves the front.
    public static let grace: Duration = .seconds(3)
    /// The next look after the app or a page was busy.
    public static let retry: Duration = .seconds(15)
    /// How long a page has to answer.
    public static let answerWithin: Duration = .seconds(1)

    public enum Decision: Equatable, Sendable {
        /// Ask the served pages, then ``pages(_:)``.
        case askPages
        /// Look again after `after`; `reason` names what held it (`updates.web.status`).
        case later(after: Duration, reason: String)
    }

    /// The app's half, for every page. `active`: cmux is in the front. `blocked`: what modal the
    /// app has open (a sheet, a modal window, a menu being tracked), nil when none. `away`: seconds
    /// since cmux left the front (infinite when it never was there).
    public static func app(active: Bool, blocked: String?, away: TimeInterval = .infinity) -> Decision {
        if let blocked { return .later(after: retry, reason: blocked) }
        if !active {
            let left = seconds(grace) - away
            // Just switched away (and maybe back): the grace runs out first.
            if left > 0 { return .later(after: .milliseconds(Int(left * 1000) + 1), reason: "grace") }
        }
        return .askPages
    }

    /// One page's input half. `focused`: the page has the keyboard (it is the first responder of
    /// cmux's key window). `idle`: seconds since the last input event. `waited`: seconds since the
    /// update was handed over. Only the page being typed into waits for input to go quiet, so a
    /// person typing in one pane never holds the others.
    public static func input(focused: Bool, active: Bool, idle: TimeInterval, waited: TimeInterval) -> Decision {
        guard focused, active else { return .askPages }
        let quiet = seconds(waited >= seconds(inputCap) ? quietInputCapped : quietInput)
        // Due when the quiet period ends, at least a second out (input may have just landed).
        if idle < quiet { return .later(after: .milliseconds(Int(max(1, quiet - idle) * 1000)), reason: "input") }
        return .askPages
    }

    /// One page's sight half. `inSight`: the page shows on screen now (its window is on screen and
    /// not covered, and the page is not hidden in it), whether cmux is in the front or not. A page in
    /// sight never reloads for a swap: a reload draws the page blank until its new document boots and
    /// restores, and an every-merge channel hands over an update every few minutes, so the chat Leo
    /// was reading and the update notes beside it blanked together, again and again (Leo,
    /// 2026-11-22: "some sort of situation just now that compLETELY blanked out this agent chat + the
    /// update notes"; "the agent pane just blanked out entirely yet again ... some sort of ultra hard
    /// reload?"). It takes the update once it is out of sight (another tab, pane or window, a
    /// minimized or covered window, a hidden app), or when it next opens.
    public static func sight(inSight: Bool) -> Decision {
        inSight ? .later(after: retry, reason: "page.in-sight") : .askPages
    }

    /// The pages' half: each page's answer, nil when a reload keeps all it holds, else why not
    /// (`page.no-answer` for a page that did not answer in time). Which pages reload (their
    /// indexes) and, when any page holds, what held the first one.
    public static func pages(_ answers: [String?]) -> (reload: [Int], held: String?) {
        (answers.indices.filter { answers[$0] == nil }, answers.lazy.compactMap { $0 }.first)
    }

    /// `duration` in seconds.
    public static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
