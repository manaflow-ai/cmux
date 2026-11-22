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
            services.accounts.model.reauthenticate(provider)
        })
        registry.bind("accounts.connect", run: { invocation in
            let provider = try provider(invocation)
            let model = services.accounts.model
            guard provider.codeRouterLink != .unsupported else { throw ActionFailure(message: AccountsAppStrings.unsupported) }
            registry.track(Task { @MainActor in
                // Fresh detection first: the CLI may run before the screen ever opened.
                model.refresh()
                for await busy in Observations({ model.isRefreshing }) where !busy { break }
                if model.row(provider).connectNeedsPaste {
                    try? services.settingsWindow.show(section: .accounts)
                    model.pasteTarget = provider
                    return ActionWorkFailure(AccountsAppStrings.pasteInSettings)
                }
                return await model.performConnect(provider).map { ActionWorkFailure($0) }
            })
        })
        registry.bind("accounts.remove", run: { invocation in
            guard let id = invocation["account"]?.stringValue?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
                throw ActionFailure(message: AccountsAppStrings.unknownAccount(""))
            }
            let model = services.accounts.model
            registry.track(Task { @MainActor in
                guard let account = await model.linkedAccount(id: id) else { return ActionWorkFailure(AccountsAppStrings.unknownAccount(id)) }
                return await model.performRemove(account).map { ActionWorkFailure($0) }
            })
        })
    }

    private static func provider(_ invocation: ActionInvocation) throws -> AIProvider {
        let raw = invocation["provider"]?.stringValue ?? ""
        guard let provider = AIProvider(rawValue: raw.lowercased()) else { throw ActionFailure(message: AccountsAppStrings.unknownProvider(raw)) }
        return provider
    }
}
