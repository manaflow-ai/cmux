public import CmuxNextSettings

/// The Agents step's in-place sign-in (logins done right; Leo: "great ui/ux for onboarding them"), as
/// the App hands it to the page: the two state keys (`signInAccounts`, `signInReadiness`, both null
/// from a daemon without `_acpmux/account/readiness`), a read of both, and the one op's forwarder
/// (`cmux.onboarding.accounts.run`). Settings > Accounts' forwarder (SettingsHarnesses.runSignIn)
/// does the work and acpmux owns every rule; this carries values only.
@MainActor
public struct OnboardingSignIn {
    public let state: @MainActor () -> (accounts: JSONValue, readiness: JSONValue)
    public let refresh: @MainActor () async -> Void
    /// One sign-in gesture's answer, unchanged; nil for an action that is none of the six.
    public let run: @MainActor (_ action: String, _ params: JSONValue) async throws -> JSONValue?

    public init(state: @escaping @MainActor () -> (accounts: JSONValue, readiness: JSONValue),
                refresh: @escaping @MainActor () async -> Void,
                run: @escaping @MainActor (_ action: String, _ params: JSONValue) async throws -> JSONValue?) {
        self.state = state
        self.refresh = refresh
        self.run = run
    }

    /// The page's op for every sign-in gesture.
    static let op = "cmux.onboarding.accounts.run"
    /// The gestures that only follow a started sign-in (its wait, a pasted code, its Cancel): they
    /// run without a click of their own; a start, switch, sign-out or remove needs one.
    nonisolated static let followUps: Set<String> = ["signInFinish", "signInCancel"]
}
