import CmuxNextActions
import CmuxNextCodeRouter
import CmuxNextSettings
import Foundation

/// Accounts actions. Every entrypoint (palette, CLI `cmux accounts …`,
/// Settings > Accounts buttons) acts through the one `AccountsModel`.
/// Secrets never travel through an action: a provider that needs a pasted
/// key opens Settings > Accounts at its paste field.
enum AccountsHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("accounts.show", run: { _ in try services.settingsWindow.show(section: .accounts) })
        // Connect Phone (palette, Window menu, the composer's machine picker, `cmux cloud
        // open-mobile-pairing`): Settings > Accounts at its iPhone rows. A phone signed in to the same
        // account finds this Mac by itself; the person allows each new phone there or in its prompt.
        registry.bind("palette.mobileConnect", run: { invocation in
            try services.settingsWindow.show(section: .accounts, setting: MobileSettings.allowIPhoneConnectionsPath.joined(separator: "."),
                                             focus: invocation.allowsViewChange)
        })
        registry.bindEffect("accounts.githubConnect", requires: nil, effect: { invocation in
            if invocation["repo"] == nil, invocation["org"] == nil { try services.settingsWindow.show(section: .accounts) } // a chat card names the repo or org: GitHub opens, Settings does not
            return .applied(result: { await services.accounts.github.connectResult(invocation) })
        })
        registry.bind("accounts.refresh", run: { _ in services.accounts.model.refresh() })
        registry.bind("accounts.reauthenticate", run: { invocation in
            let provider = try provider(invocation)
            guard provider.reauthPlan != .none else { throw ActionFailure(message: AccountsAppStrings.nothingToSignIn) }
            registry.track(Task { @MainActor [model = services.accounts.model] in await model.performReauthenticate(provider).map { ActionWorkFailure($0) } })
        })
    }

    private static func provider(_ invocation: ActionInvocation) throws -> AIProvider {
        let raw = invocation["provider"]?.stringValue ?? ""
        guard let provider = AIProvider(rawValue: raw.lowercased()) else { throw ActionFailure(message: AccountsAppStrings.unknownProvider(raw)) }
        return provider
    }
}
