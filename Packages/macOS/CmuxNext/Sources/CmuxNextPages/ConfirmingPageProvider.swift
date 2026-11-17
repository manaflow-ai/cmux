public import AppKit
public import CmuxNextSettings
public import Foundation

/// Puts a native confirmation in front of the page calls that need one (react-pages.md 3.3). For
/// each call `describe` returns the sheet, or nil for a call that needs none. The person's own
/// fresh click or key in the page (``PageCallContext/gestureEvent``, tracked by the host, never by
/// page script) is the confirmation: the call reaches `inner` as the user's with no sheet, and the
/// click is spent. A call with no such click (page script alone, the CLI, the palette, MCP) and a
/// sheet that asks even after a click (``PageConfirmation/asksAfterClick``) show the sheet. A
/// declined call fails with `cmux.page.cancelled` and never reaches `inner`; an approved call
/// reaches it with `context.confirmed == true`.
@MainActor
public final class ConfirmingPageProvider: PageProvider {
    public typealias Describe = @MainActor (_ op: String, _ params: JSONValue) async throws -> PageConfirmation?

    private let inner: any PageProvider
    private let describe: Describe
    private let presenter: any PageConfirmationPresenter
    private var clicks = PageGestureSpender()
    /// The view the sheet attaches to (the page view).
    public var anchor: () -> NSView? = { nil }

    public init(inner: any PageProvider, presenter: any PageConfirmationPresenter, describe: @escaping Describe) {
        self.inner = inner
        self.presenter = presenter
        self.describe = describe
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let confirmation = try await describe(op, params) else {
            return try await inner.call(op, params: params, context: context)
        }
        let clicked = !confirmation.asksAfterClick && clicks.spend(context)
        if !clicked {
            guard await presenter.confirm(confirmation, anchor: anchor()) else { throw PageError.cancelled }
        }
        return try await inner.call(op, params: params, context: PageCallContext(page: context.page, origin: "user", confirmed: true, opid: context.opid))
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        try await inner.subscribe(stream, filter: filter, context: context, onEvent: onEvent)
    }
}

/// The person's fresh click or key in a page view, spent once: ``spend(_:)`` answers true for the
/// first call that carries a given event (``PageCallContext/gestureEvent``), false for page script
/// alone and for the same event again, so one click backs one call.
public nonisolated struct PageGestureSpender: Sendable, Hashable {
    private var spent: TimeInterval?

    public init() {}

    public mutating func spend(_ context: PageCallContext) -> Bool {
        guard context.userGesture, let event = context.gestureEvent, event != spent else { return false }
        spent = event
        return true
    }
}
