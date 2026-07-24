@testable import CmuxSubrouter

/// A scriptable ``SubrouterAccountSwitching`` that records invocations.
actor FakeAccountSwitcher: SubrouterAccountSwitching {
    struct Invocation: Equatable {
        var provider: SubrouterProvider
        var accountID: String
        var commandPath: String?
    }

    var errorToThrow: SubrouterSwitchError?
    private(set) var invocations: [Invocation] = []
    /// Runs while the fake "sr" call is in flight, so tests can mutate the
    /// store mid-switch (e.g. disable the integration).
    private var onSwitch: (@Sendable () async -> Void)?

    func setError(_ error: SubrouterSwitchError?) {
        errorToThrow = error
    }

    func setOnSwitch(_ callback: (@Sendable () async -> Void)?) {
        onSwitch = callback
    }

    func switchAccount(
        provider: SubrouterProvider,
        accountID: String,
        commandPath: String?
    ) async throws {
        invocations.append(
            Invocation(provider: provider, accountID: accountID, commandPath: commandPath)
        )
        if let onSwitch {
            await onSwitch()
        }
        if let errorToThrow {
            throw errorToThrow
        }
    }
}
