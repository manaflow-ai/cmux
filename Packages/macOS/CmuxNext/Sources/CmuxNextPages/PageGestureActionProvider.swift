public import CmuxNextSettings
public import Foundation

/// Runs a page's ``PageDescriptor/gestureActions`` as the person's own: a `cmux.app.action.run` for
/// one of them, made on the person's fresh click or key in this page view (tracked by the host, never
/// by page script) and on a gesture no earlier run spent, reaches the wrapped native provider as a
/// `user` call, so the action runs as from the palette (Home's New Cloud Machine opens its setup
/// sheet and sign-in). Every other call, a spent gesture's included, passes through unchanged.
@MainActor
public final class PageGestureActionProvider: PageProvider {
    private let page: PageDescriptor
    private let inner: any PageProvider
    /// The gesture the last run spent (`PageCallContext.gestureEvent`).
    private var spentGesture: TimeInterval?

    public init(page: PageDescriptor, wrapping inner: any PageProvider) {
        self.page = page
        self.inner = inner
    }

    /// Whether `action` runs as the person's own on `context`; a `true` answer spends its gesture.
    public func runsAsPerson(_ action: String, _ context: PageCallContext) -> Bool {
        guard page.gestureActions.contains(action), context.page == page.id, context.userGesture,
              let event = context.gestureEvent, event != spentGesture else { return false }
        spentGesture = event
        return true
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == PageNativeOp.actionRun, let action = params["action"]?.stringValue, runsAsPerson(action, context) else {
            return try await inner.call(op, params: params, context: context)
        }
        let person = PageCallContext(page: context.page, origin: "user", confirmed: true, opid: context.opid,
                                     userGesture: true, gestureEvent: context.gestureEvent)
        return try await inner.call(op, params: params, context: person)
    }

    public func pageDidClose() {
        inner.pageDidClose()
    }
}
