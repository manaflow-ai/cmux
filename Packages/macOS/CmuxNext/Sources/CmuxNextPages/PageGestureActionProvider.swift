public import CmuxNextSettings
public import Foundation

/// Runs a page's ``PageDescriptor/gestureActions`` as the person's own: a `cmux.app.action.run` for
/// one of them, made on the person's fresh click or key in this page view (tracked by the host, never
/// by page script) and on a gesture no earlier run spent, reaches the wrapped native provider as a
/// `user` call, so the action runs as from the palette (Home's New Cloud Machine opens its setup
/// sheet and sign-in). Every other call, a spent gesture's included, passes through unchanged.
/// SECURITY: a ``PageDescriptor/personBackedActions`` run that comes with a gesture the HID system did
/// not make (`backs`: a click another process posted reaches WebKit as a real event) is refused, never
/// promoted; with no `backs`, none is backed.
@MainActor
public final class PageGestureActionProvider: PageProvider {
    private let page: PageDescriptor
    private let inner: any PageProvider
    /// Whether the gesture at this uptime was the HID system's own input (`PersonInputLedger.backs`).
    private let backs: (@MainActor (TimeInterval) -> Bool)?
    /// The refusal a page shows for an unbacked ``PageDescriptor/personBackedActions`` run.
    private let refusal: String
    /// The gesture the last run spent (`PageCallContext.gestureEvent`).
    private var spentGesture: TimeInterval?

    public init(page: PageDescriptor, wrapping inner: any PageProvider, backs: (@MainActor (TimeInterval) -> Bool)? = nil,
                refusal: String = "") {
        self.page = page
        self.inner = inner
        self.backs = backs
        self.refusal = refusal
    }

    /// Whether `action` runs as the person's own on `context`; a `true` answer spends its gesture.
    public func runsAsPerson(_ action: String, _ context: PageCallContext) -> Bool {
        guard page.gestureActions.contains(action), context.page == page.id, context.userGesture,
              let event = context.gestureEvent, event != spentGesture,
              !page.personBackedActions.contains(action) || backs?(event) == true else { return false }
        spentGesture = event
        return true
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == PageNativeOp.actionRun, let action = params["action"]?.stringValue else {
            return try await inner.call(op, params: params, context: context)
        }
        if page.personBackedActions.contains(action), context.userGesture,
           !(context.gestureEvent.map { backs?($0) == true } ?? false) {
            throw PageError(code: PageNativeOp.userOnlyCode, message: refusal)
        }
        guard runsAsPerson(action, context) else { return try await inner.call(op, params: params, context: context) }
        let person = PageCallContext(page: context.page, origin: "user", confirmed: true, opid: context.opid,
                                     userGesture: true, gestureEvent: context.gestureEvent)
        return try await inner.call(op, params: params, context: person)
    }

    public func pageDidClose() {
        inner.pageDidClose()
    }
}
