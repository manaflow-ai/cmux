public import CmuxNextSettings
public import Foundation

/// The owner side of one or more page namespaces: a relay to the daemon (`cmux.history.*` ->
/// `history.*` v2 ops) or the app's native UI ops. Providers never see a call the page's
/// descriptor does not admit; params arrive without an `origin` (the context has it).
@MainActor
public protocol PageProvider: AnyObject {
    /// Answers one call or throws ``PageError``.
    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue
    /// Starts an event stream with the page's `filter` (an object, possibly empty); `onEvent` runs
    /// on the main actor for each event, in order.
    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription
}

public extension PageProvider {
    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        throw PageError.unknownOp(stream)
    }
}
