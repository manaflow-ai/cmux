public import CmuxNextSettings

/// A namespace an organization policy can turn off (DisabledFeatures): while `turnedOff` answers a
/// reason, every call and stream is refused with it (`cmux.policy.turned_off`), so a page that was
/// open before the policy arrived stops too.
@MainActor
public final class PolicyGatedPageProvider: PageProvider {
    private let inner: any PageProvider
    private let turnedOff: @MainActor () -> String?

    /// Wraps a provider with the current organization policy refusal.
    public init(inner: any PageProvider, turnedOff: @escaping @MainActor () -> String?) {
        self.inner = inner
        self.turnedOff = turnedOff
    }

    public func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        if let reason = turnedOff() { throw PageError(code: "cmux.policy.turned_off", message: reason) }
        return try await inner.call(op, params: params, context: context)
    }

    public func subscribe(_ stream: String, filter: CmuxNextSettings.JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (CmuxNextSettings.JSONValue) -> Void) async throws -> PageSubscription {
        if let reason = turnedOff() { throw PageError(code: "cmux.policy.turned_off", message: reason) }
        return try await inner.subscribe(stream, filter: filter, context: context, onEvent: onEvent)
    }
}
