public import CmuxNextCodeRouter
public import Foundation
public import Observation

/// The Accounts screen: one ``AccountRowState`` per provider, fed by
/// detection, CodeRouter and the user's buttons. Every operation is async
/// and runs off the main actor in the services; the model only applies
/// row events. Settings and onboarding share one model.
@MainActor
@Observable
public final class AccountsModel {
    public private(set) var rows: [AccountRowState]
    public private(set) var isRefreshing = false
    /// The provider whose paste sheet is open (a key or a Claude token).
    public var pasteTarget: AIProvider?
    /// The provider whose Connect confirmation is open (Codex: its refresh
    /// token moves to CodeRouter).
    public var confirmTarget: AIProvider?
    @ObservationIgnored public let services: any AccountsServices
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Providers whose login was started here; re-detected on activation.
    @ObservationIgnored private var pendingReauth: Set<AIProvider> = []

    public init(services: any AccountsServices) {
        self.services = services
        rows = AIProvider.allCases.map(AccountRowState.init(provider:))
    }

    public func row(_ provider: AIProvider) -> AccountRowState {
        rows.first { $0.provider == provider } ?? AccountRowState(provider: provider)
    }

    /// Rows of one group, in catalog order. OpenCode Go shows only when CodeRouter holds one.
    public func rows(in group: AIProvider.Group) -> [AccountRowState] {
        rows.filter { $0.provider.group == group && ($0.provider != .openCodeGo || !$0.linked.isEmpty) }
    }

    public var isSignedInToCmux: Bool { services.isSignedInToCmux }

    /// Why CodeRouter's list could not be read, if any row says so.
    public var codeRouterProblem: String? { rows.lazy.compactMap(\.codeRouterProblem).first }

    /// Detects every provider and reloads CodeRouter's accounts. A newer
    /// refresh supersedes an older one; stale results are dropped.
    public func refresh() {
        generation += 1
        let current = generation
        refreshTask?.cancel()
        isRefreshing = true
        apply(.detectionStarted)
        apply(.cmuxSignIn(services.isSignedInToCmux))
        let services = services
        refreshTask = Task { [weak self] in
            // Detection and the CodeRouter list run concurrently.
            let detecting = Task { await services.detect() }
            let loading = Task { await Self.loadLinked(services) }
            let found = await detecting.value, accounts = await loading.value
            guard let self, current == self.generation, !Task.isCancelled else { return }
            for detection in found { self.apply(.detected(detection), to: detection.provider) }
            switch accounts {
            case .success(let list): self.apply(.linkedLoaded(list))
            case .failure(let message): self.apply(.linkedFailed(message))
            case nil: break
            }
            self.isRefreshing = false
        }
    }

    /// The app became active: re-detect if a login ran in a tab meanwhile.
    public func appDidBecomeActive() {
        guard !pendingReauth.isEmpty else { return }
        for provider in pendingReauth { apply(.reauthEnded, to: provider) }
        pendingReauth.removeAll()
        refresh()
    }

    public func reauthenticate(_ provider: AIProvider) {
        guard row(provider).canReauthenticate, !row(provider).isBusy else { return }
        apply(.reauthStarted, to: provider)
        pendingReauth.insert(provider)
        services.reauthenticate(provider, plan: provider.reauthPlan)
    }

    /// Connect: asks for a paste first when there is no local secret to send.
    public func connect(_ provider: AIProvider, pasted: String? = nil, confirmed: Bool = false) {
        let state = row(provider)
        guard state.canConnect, !state.isBusy else { return }
        if pasted == nil, state.connectNeedsPaste {
            pasteTarget = provider
            return
        }
        if Self.needsConfirmation(provider), !confirmed {
            confirmTarget = provider
            return
        }
        confirmTarget = nil
        // The row shows Connecting at once; the request runs after.
        apply(.connectStarted, to: provider)
        Task { await runConnect(provider, pasted: pasted) }
    }

    /// Connecting Codex hands its refresh token to CodeRouter, which then
    /// refreshes it: the user confirms after reading that note.
    public static func needsConfirmation(_ provider: AIProvider) -> Bool { provider.codeRouterLink == .codexOAuth }

    /// Connects and waits; returns the failure text, or nil on success
    /// (the palette and CLI report it).
    @discardableResult
    public func performConnect(_ provider: AIProvider, pasted: String? = nil) async -> String? {
        let state = row(provider)
        guard state.canConnect else { return state.isLinkable ? AccountsStrings.errorNotSignedIn : AccountsStrings.unsupported }
        guard !state.isBusy else { return nil }
        apply(.connectStarted, to: provider)
        return await runConnect(provider, pasted: pasted)
    }

    private func runConnect(_ provider: AIProvider, pasted: String?) async -> String? {
        do {
            try await services.connect(provider, pasted: pasted)
            let accounts = (try? await services.linkedAccounts()) ?? []
            apply(.connectSucceeded(accounts), to: provider)
            return nil
        } catch {
            let message = AccountsStrings.message(for: error)
            apply(.connectFailed(message), to: provider)
            return message
        }
    }

    public func remove(_ account: LinkedAccount) {
        guard !row(account.provider).isBusy else { return }
        apply(.removeStarted(accountID: account.id), to: account.provider)
        guard case .removing = row(account.provider).phase else { return }
        Task { await runRemove(account) }
    }

    /// Removes and waits; returns the failure text, or nil.
    @discardableResult
    public func performRemove(_ account: LinkedAccount) async -> String? {
        guard !row(account.provider).isBusy else { return nil }
        apply(.removeStarted(accountID: account.id), to: account.provider)
        guard case .removing = row(account.provider).phase else { return nil }
        return await runRemove(account)
    }

    private func runRemove(_ account: LinkedAccount) async -> String? {
        do {
            try await services.remove(account)
            let accounts = (try? await services.linkedAccounts()) ?? []
            apply(.removeSucceeded(accounts), to: account.provider)
            return nil
        } catch {
            let message = AccountsStrings.message(for: error)
            apply(.removeFailed(message), to: account.provider)
            return message
        }
    }

    /// The linked account with `id`, from the last list or a fresh one.
    public func linkedAccount(id: String) async -> LinkedAccount? {
        if let known = rows.lazy.flatMap(\.linked).first(where: { $0.id == id }) { return known }
        guard let accounts = try? await services.linkedAccounts() else { return nil }
        apply(.linkedLoaded(accounts))
        return accounts.first { $0.id == id }
    }

    /// Saves a pasted key to the Keychain; returns the failure text, or nil.
    @discardableResult
    public func saveKey(_ key: String, for provider: AIProvider) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AccountsStrings.errorNeedsPaste }
        do {
            try services.saveKey(trimmed, for: provider)
        } catch {
            return AccountsStrings.message(for: error)
        }
        refresh()
        return nil
    }

    public func deleteSavedKey(for provider: AIProvider) {
        try? services.deleteSavedKey(for: provider)
        refresh()
    }

    // MARK: Events

    private func apply(_ event: AccountRowState.Event) {
        for index in rows.indices { rows[index].reduce(event) }
    }

    private func apply(_ event: AccountRowState.Event, to provider: AIProvider) {
        guard let index = rows.firstIndex(where: { $0.provider == provider }) else { return }
        rows[index].reduce(event)
    }

    private enum Linked { case success([LinkedAccount]), failure(String) }

    private static func loadLinked(_ services: any AccountsServices) async -> Linked? {
        guard services.isSignedInToCmux else { return nil }
        do {
            return .success(try await services.linkedAccounts())
        } catch {
            return .failure(AccountsStrings.message(for: error))
        }
    }
}
