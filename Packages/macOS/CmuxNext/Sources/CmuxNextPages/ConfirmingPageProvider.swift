public import AppKit
public import CmuxNextSettings
public import Foundation

/// Puts a native confirmation in front of the page calls that need a person (react-pages.md 3.3,
/// coordinator Q4). For each call `describe` returns the sheet to show, or nil for a call that
/// needs none. A declined call fails with `cmux.page.cancelled` and never reaches `inner`; an
/// approved call reaches it with `context.confirmed == true`.
@MainActor
public final class ConfirmingPageProvider: PageProvider {
    public typealias Describe = @MainActor (_ op: String, _ params: JSONValue) async throws -> PageConfirmation?

    private let inner: any PageProvider
    private let describe: Describe
    private let presenter: any PageConfirmationPresenter
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
        guard await presenter.confirm(confirmation, anchor: anchor()) else { throw PageError.cancelled }
        return try await inner.call(op, params: params, context: PageCallContext(page: context.page, origin: "user", confirmed: true))
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        try await inner.subscribe(stream, filter: filter, context: context, onEvent: onEvent)
    }
}
