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

    func setError(_ error: SubrouterSwitchError?) {
        errorToThrow = error
    }

    func switchAccount(
        provider: SubrouterProvider,
        accountID: String,
        commandPath: String?
    ) async throws {
        invocations.append(
            Invocation(provider: provider, accountID: accountID, commandPath: commandPath)
        )
        if let errorToThrow {
            throw errorToThrow
        }
    }
}
