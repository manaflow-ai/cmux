public import CmuxNextSettings
public import Foundation

/// Two-finger Back / Forward over a page (webviews/src/swipeNavigation): the router only carries it.
/// The host forwards trackpad events on ``PageNativeOp/pageSwipe`` (``PageSwipeForwarder``); the page
/// decides and answers with ``PageNativeOp/historyNavigate`` or ``PageNativeOp/swipeRelease``.
public extension PageNativeOp {
    /// Stream every page may subscribe to: one trackpad scroll event over the page,
    /// `{g, phase, momentum, dx, dy, inverted, time, back?, forward?}` (``PageSwipeEvent``).
    static let pageSwipe = "cmux.page.swipe"
    /// Built in for every page: run the app's Go Back (`{back: true, g}`) or Go Forward for forwarded
    /// gesture `g`; answers `{navigated}`.
    static let historyNavigate = "cmux.app.history.navigate"
    /// Built in for every page: `{g}`, the page is done with forwarded gesture `g`.
    static let swipeRelease = "cmux.app.swipe.release"
    /// Built in for every page (app health, webviews/src/pages/shared/pageHealth.ts): `{handled, edits?}`,
    /// the page is alive, has handled that many key and pointer presses, and holds unsaved edits now
    /// (`edits: true`, `[data-cmux-unsaved-edits]`); answers null.
    static let pageHeartbeat = "cmux.page.heartbeat"
    /// Host to page, `{}` → `{saved}`: the page saves its scroll and draft now; the host reloads it next.
    static let pageSaveState = "cmux.page.save_state"
    /// The streams the router serves itself, for every page.
    static let builtInStreams: Set<String> = [pageCommand, pageConnection, pagePopup, pageSwipe]
}

extension PageRouter {
    /// Answers the ops the router serves itself with no descriptor entry: the title bar double-click,
    /// the swipe's two and the app health heartbeat. Nil for every other op.
    func hostCall(_ op: String, params: JSONValue) throws -> JSONValue? {
        switch op {
        case PageNativeOp.pageHeartbeat:
            guard !closed else { throw PageError.closed }
            let handled = params["handled"]?.doubleValue.flatMap { $0.isFinite && $0 >= 0 ? UInt64(min($0, 9_007_199_254_740_991)) : nil } ?? 0
            heartbeat?(handled, params["edits"]?.boolValue == true)
            return .null
        case PageNativeOp.titleBarDoubleClick:
            guard !closed else { throw PageError.closed }
            titleBarDoubleClick?()
            return .object([:])
        case PageNativeOp.historyNavigate:
            guard !closed else { throw PageError.closed }
            guard let back = params["back"]?.boolValue else { throw PageError.invalidParams("back must be a boolean") }
            guard let gesture = params["g"]?.doubleValue, let id = Int(exactly: gesture) else {
                throw PageError.invalidParams("g must be the forwarded gesture's id")
            }
            return ["navigated": .bool(historyNavigate?(back, id) ?? false)]
        case PageNativeOp.swipeRelease:
            guard !closed else { throw PageError.closed }
            if let gesture = params["g"]?.doubleValue, let id = Int(exactly: gesture) { swipeRelease?(id) }
            return .object([:])
        default:
            return nil
        }
    }

    /// Whether page code listens on ``PageNativeOp/pageSwipe`` (no listener: nothing is forwarded).
    public var hasSwipeSubscriber: Bool {
        !closed && builtIn.values.contains(PageNativeOp.pageSwipe)
    }

    /// Sends one forwarded trackpad event to the page's swipe subscribers.
    public func publishSwipe(_ event: JSONValue) {
        for sub in builtIn.filter({ $0.value == PageNativeOp.pageSwipe }).keys.sorted() { deliver(sub: sub, event) }
    }
}
