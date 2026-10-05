public import CmuxNextCodeRouter
public import Foundation

/// The Accounts screen as data for the React Settings page (R82 commit 3): the same rows, buttons,
/// outcomes, confirmation and paste form the SwiftUI view draws, with every text already
/// localized here (this module owns the Accounts strings). The page draws it and sends one
/// ``AccountsPageAction`` per gesture; the model does the rest, as for the SwiftUI view.
public struct AccountsPageState: Encodable, Equatable, Sendable {
    public struct Button: Encodable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let disabled: Bool
        public let help: String?
        public let destructive: Bool
    }

    public struct Linked: Encodable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let state: String
        public let healthy: Bool
        public let busy: Bool
    }

    public struct Notice: Encodable, Equatable, Sendable {
        /// `success`, `neutral`, `danger` or `attention`.
        public let kind: String
        public let text: String
    }

    public struct Confirm: Encodable, Equatable, Sendable {
        public let text: String
        public let confirm: String
        public let cancel: String
    }

    public struct Paste: Encodable, Equatable, Sendable {
        public let title: String
        public let body: String
        public let placeholder: String
        /// Buttons by id: `setupToken`, `saveKeychain`, `sendCodeRouter`, `cancel`.
        public let buttons: [Button]
    }

    public struct Row: Encodable, Equatable, Sendable {
        public let provider: String
        public let name: String
        public let detail: String?
        public let status: String
        /// `success`, `attention`, `neutral` or `quiet` (the status dot).
        public let statusKind: String
        public let busy: Bool
        public let buttons: [Button]
        public let unsupported: String?
        public let linked: [Linked]
        public let note: String?
        public let outcome: Notice?
        public let confirm: Confirm?
        public let paste: Paste?
    }

    public struct Group: Encodable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let rows: [Row]
    }

    public let intro: String
    public let refresh: String
    public let refreshing: Bool
    /// The sign-in banner when cmux is signed out: its text and button.
    public let signIn: Confirm?
    public let problem: String?
    public let removeTitle: String
    public let groups: [Group]
}

/// One gesture on the Accounts part of the Settings page.
public enum AccountsPageAction: Equatable, Sendable {
    case refresh, signInToCmux
    case reauthenticate(AIProvider), addKey(AIProvider), deleteSavedKey(AIProvider), connect(AIProvider)
    case confirmConnect(AIProvider), cancelConfirm
    case remove(accountID: String)
    case runSetupToken, cancelPaste
    case saveKey(AIProvider, String), sendToCodeRouter(AIProvider, String)

    /// Parses `{action, provider?, account?, secret?}`; nil for an unknown action or provider.
    public init?(action: String, provider: String?, account: String?, secret: String?) {
        let provider = provider.flatMap(AIProvider.init(rawValue:))
        switch (action, provider) {
        case ("refresh", _): self = .refresh
        case ("signIn", _): self = .signInToCmux
        case ("reauth", let provider?): self = .reauthenticate(provider)
        case ("addKey", let provider?): self = .addKey(provider)
        case ("deleteKey", let provider?): self = .deleteSavedKey(provider)
        case ("connect", let provider?): self = .connect(provider)
        case ("confirm", let provider?): self = .confirmConnect(provider)
        case ("cancelConfirm", _): self = .cancelConfirm
        case ("remove", _):
            guard let account, !account.isEmpty else { return nil }
            self = .remove(accountID: account)
        case ("setupToken", _): self = .runSetupToken
        case ("cancelPaste", _): self = .cancelPaste
        case ("saveKeychain", let provider?):
            guard let secret else { return nil }
            self = .saveKey(provider, secret)
        case ("sendCodeRouter", let provider?):
            guard let secret else { return nil }
            self = .sendToCodeRouter(provider, secret)
        default: return nil
        }
    }
}

extension AccountsModel {
    /// The screen as the Settings page draws it.
    public var pageState: AccountsPageState {
        AccountsPageState(
            intro: AccountsStrings.intro, refresh: AccountsStrings.refresh, refreshing: isRefreshing,
            signIn: isSignedInToCmux ? nil : .init(text: AccountsStrings.cmuxSignedOut, confirm: AccountsStrings.signInToCmux, cancel: ""),
            problem: isSignedInToCmux ? codeRouterProblem.map(AccountsStrings.codeRouterUnavailable) : nil,
            removeTitle: AccountsStrings.remove,
            groups: AIProvider.Group.allCases.compactMap { group in
                let rows = rows(in: group)
                return rows.isEmpty ? nil : .init(id: group.rawValue, title: AccountsStrings.group(group), rows: rows.map(pageRow))
            })
    }

    /// Runs one page gesture. Returns the failure text of a Keychain save (the page shows it in
    /// the paste form), else nil. A secret is never kept or logged here.
    @discardableResult
    public func perform(_ action: AccountsPageAction) async -> String? {
        switch action {
        case .refresh: refresh()
        case .signInToCmux: services.signInToCmux()
        case .reauthenticate(let provider): reauthenticate(provider)
        case .addKey(let provider): pasteTarget = provider
        case .deleteSavedKey(let provider): deleteSavedKey(for: provider)
        case .connect(let provider): connect(provider)
        case .confirmConnect(let provider): connect(provider, confirmed: true)
        case .cancelConfirm: confirmTarget = nil
        case .remove(let id):
            if let account = await linkedAccount(id: id) { remove(account) }
        case .runSetupToken: services.runClaudeSetupToken()
        case .cancelPaste: pasteTarget = nil
        case .saveKey(let provider, let secret):
            if let error = saveKey(secret, for: provider) { return error }
            pasteTarget = nil
        case .sendToCodeRouter(let provider, let secret):
            pasteTarget = nil
            connect(provider, pasted: secret)
        }
        return nil
    }

    private func pageRow(_ row: AccountRowState) -> AccountsPageState.Row {
        let provider = row.provider
        var buttons: [AccountsPageState.Button] = []
        if row.canReauthenticate {
            buttons.append(.init(id: "reauth", title: AccountsStrings.reauthTitle(row), disabled: row.isBusy, help: nil, destructive: false))
        }
        if provider.acceptsPastedKey {
            buttons.append(.init(id: "addKey", title: AccountsStrings.addKey, disabled: row.isBusy, help: nil, destructive: false))
            if row.detection?.sources.contains(.cmuxKeychain) == true {
                buttons.append(.init(id: "deleteKey", title: AccountsStrings.deleteSavedKey, disabled: false, help: nil, destructive: false))
            }
        }
        if row.isLinkable {
            buttons.append(.init(id: "connect", title: AccountsStrings.connect, disabled: row.isBusy || !row.canConnect,
                                 help: isSignedInToCmux ? nil : AccountsStrings.cmuxSignedOut, destructive: false))
        }
        let outcome: AccountsPageState.Notice? = switch row.outcome {
        case .connected: .init(kind: "success", text: AccountsStrings.connected)
        case .removed: .init(kind: "neutral", text: AccountsStrings.removed)
        case .failed(let message): .init(kind: "danger", text: message)
        case nil: nil
        }
        return AccountsPageState.Row(
            provider: provider.rawValue, name: provider.displayName, detail: Self.detail(row),
            status: AccountsStrings.status(row), statusKind: Self.statusKind(row), busy: row.isBusy && row.phase != .detecting,
            buttons: buttons,
            unsupported: !row.isLinkable && !provider.isLocalServer ? AccountsStrings.unsupported : nil,
            linked: row.linked.map { account in
                .init(id: account.id, label: account.label, state: account.state, healthy: account.isHealthy,
                      busy: row.phase == .removing(accountID: account.id))
            },
            note: provider.codeRouterLink == .bedrockKeys && isSignedInToCmux && !row.hasBedrockKeys ? AccountsStrings.bedrockNeedsKeys : nil,
            outcome: outcome,
            confirm: confirmTarget == provider
                ? .init(text: AccountsStrings.codexRefreshNote, confirm: AccountsStrings.confirmConnect, cancel: AccountsStrings.cancel) : nil,
            paste: pasteTarget == provider ? pasteForm(provider) : nil)
    }

    private func pasteForm(_ provider: AIProvider) -> AccountsPageState.Paste {
        var buttons: [AccountsPageState.Button] = []
        if provider == .claude {
            buttons.append(.init(id: "setupToken", title: AccountsStrings.runSetupToken, disabled: false, help: nil, destructive: false))
        }
        if provider.acceptsPastedKey {
            buttons.append(.init(id: "saveKeychain", title: AccountsStrings.saveToKeychain, disabled: false, help: nil, destructive: false))
        }
        if provider.codeRouterLink != .unsupported {
            buttons.append(.init(id: "sendCodeRouter", title: AccountsStrings.sendToCodeRouter, disabled: !isSignedInToCmux, help: nil, destructive: false))
        }
        buttons.append(.init(id: "cancelPaste", title: AccountsStrings.cancel, disabled: false, help: nil, destructive: false))
        return .init(title: provider == .claude ? AccountsStrings.pasteClaudeTitle : AccountsStrings.pasteKeyTitle(provider.displayName),
                     body: provider == .claude ? AccountsStrings.pasteClaudeBody : AccountsStrings.pasteKeyBody,
                     placeholder: AccountsStrings.pastePlaceholder, buttons: buttons)
    }

    /// A redacted account label, plan, detail and source; never an email or a secret.
    static func detail(_ row: AccountRowState) -> String? {
        guard let detection = row.detection else { return nil }
        let display = detection.account?.display
        let parts = [display, detection.plan == display ? nil : detection.plan, detection.detail,
                     detection.sources.first.map { AccountsStrings.source($0.label) }]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    static func statusKind(_ row: AccountRowState) -> String {
        guard row.phase != .detecting, let status = row.status else { return "quiet" }
        switch status {
        case .signedIn: return "success"
        case .expired: return "attention"
        case .missing: return "quiet"
        case .unknown: return "neutral"
        }
    }
}
