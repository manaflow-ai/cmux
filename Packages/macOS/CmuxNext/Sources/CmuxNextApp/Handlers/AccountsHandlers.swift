import CmuxNextActions
import CmuxNextCodeRouter
import CmuxNextSettings
import Foundation

/// Accounts and CodeRouter actions. Every entrypoint (palette, CLI
/// `cmux accounts …`, Settings > Accounts buttons) acts through the one
/// `AccountsModel`; connect and remove report their outcome to the caller.
/// Secrets never travel through an action: a provider that needs a pasted
/// key or token opens Settings > Accounts at its paste field.
enum AccountsHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("accounts.show", run: { _ in try services.settingsWindow.show(section: .accounts) })
        registry.bind("accounts.refresh", run: { _ in services.accounts.model.refresh() })
        registry.bind("accounts.reauthenticate", run: { invocation in
            let provider = try provider(invocation)
            guard provider.reauthPlan != .none else { throw ActionFailure(message: AccountsAppStrings.nothingToSignIn) }
            guard services.windows.active?.focusedPane != nil else { throw ActionFailure(message: AccountsAppStrings.noWindow) }
            let model = services.accounts.model
            // The login is awaited off the action's turn; its outcome is one task of the run's completion.
            registry.trackWork(owner: "AccountsHandlers.reauthenticate", on: services.mainWork) {
                await model.performReauthenticate(provider)
            } then: { result in
                (try? result.get()).flatMap { $0 }.map { ActionWorkFailure($0) }
            }
        })
        registry.bind("accounts.connect", run: { invocation in
            let provider = try provider(invocation)
            let model = services.accounts.model
            guard provider.codeRouterLink != .unsupported else { throw ActionFailure(message: AccountsAppStrings.unsupported) }
            registry.trackWork(owner: "AccountsHandlers.connect", on: services.mainWork) {
                await connect(provider, model: model)
            } then: { [weak services] result in
                switch result {
                case .success(.needsPaste):
                    // A provider that needs a pasted key opens Settings > Accounts at its paste field.
                    try? services?.settingsWindow.show(section: .accounts)
                    model.pasteTarget = provider
                    return ActionWorkFailure(AccountsAppStrings.pasteInSettings)
                case .success(.connected(let failure)):
                    return failure.map { ActionWorkFailure($0) }
                case .failure(let error):
                    return ActionWorkFailure(String(describing: error))
                }
            }
        })
        registry.bind("accounts.remove", run: { invocation in
            guard let id = invocation["account"]?.stringValue?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
                throw ActionFailure(message: AccountsAppStrings.unknownAccount(""))
            }
            let model = services.accounts.model
            registry.trackWork(owner: "AccountsHandlers.remove", on: services.mainWork) { () -> String? in
                guard let account = await model.linkedAccount(id: id) else { return AccountsAppStrings.unknownAccount(id) }
                return await model.performRemove(account)
            } then: { result in
                (try? result.get()).flatMap { $0 }.map { ActionWorkFailure($0) }
            }
        })
    }

    /// How `accounts.connect` ended before its last step on main.
    private nonisolated enum ConnectStep: Sendable {
        /// The provider takes a pasted key or token, which only Settings > Accounts asks for.
        case needsPaste
        /// The connect ran; its failure, or nil.
        case connected(String?)
    }

    /// Detects the accounts again (the CLI may run before the screen ever opened), then connects `provider`
    /// unless it takes a pasted secret.
    private static func connect(_ provider: AIProvider, model: AccountsModel) async -> ConnectStep {
        model.refresh()
        await model.settle()
        if model.row(provider).connectNeedsPaste { return .needsPaste }
        return .connected(await model.performConnect(provider))
    }

    private static func provider(_ invocation: ActionInvocation) throws -> AIProvider {
        let raw = invocation["provider"]?.stringValue ?? ""
        guard let provider = AIProvider(rawValue: raw.lowercased()) else { throw ActionFailure(message: AccountsAppStrings.unknownProvider(raw)) }
        return provider
    }
}
