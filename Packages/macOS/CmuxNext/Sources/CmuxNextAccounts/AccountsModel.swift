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
    /// Why the last team switch failed, until the next switch or refresh.
    public private(set) var teamError: String?
    @ObservationIgnored public let services: any AccountsServices
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Providers whose login was started here; re-detected on activation.
    @ObservationIgnored private var pendingReauth: Set<AIProvider> = []
    /// A detection has finished. Until then every row reads Checking… and
    /// refuses work, which the palette and CLI meet before the screen opens.
    @ObservationIgnored private var hasDetected = false

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
        teamError = nil
        isRefreshing = true
        apply(.detectionStarted)
        apply(.cmuxSignIn(services.isSignedInToCmux))
        let services = services
        refreshTask = Task { [weak self] in
            // Detection and the CodeRouter list run concurrently.
            let detecting = Task { await services.detect() }
            let loading = Task { await Self.loadLinked(services) }
            // Membership re-reads on its own; the team list updates when it lands.
            if let active = services.activeTeam { Task { await active.refresh() } }
            let found = await detecting.value, accounts = await loading.value
            guard let self, current == self.generation, !Task.isCancelled else { return }
            for detection in found { self.apply(.detected(detection), to: detection.provider) }
            self.hasDetected = true
            switch accounts {
            case .success(let list): self.apply(.linkedLoaded(list))
            case .failure(let message): self.apply(.linkedFailed(message))
            case nil: break
            }
            self.isRefreshing = false
        }
    }

    /// Makes `id` the active team. The App reloads what follows the team
    /// (this screen's CodeRouter accounts included) when the switch lands.
    public func selectTeam(_ id: String) async {
        teamError = nil
        guard let active = services.activeTeam else { return }
        do {
            try await active.select(id)
        } catch {
            teamError = AccountsStrings.teamSwitchFailed
        }
    }

    /// Waits for the running refresh, first starting one when no detection
    /// has finished yet or a login started here may have ended, so an action
    /// never meets rows that are still Checking… or Re-authenticating (a
    /// login in a cmux tab never makes the app inactive).
    public func settle() async {
        let loginMayHaveEnded = rows.contains { $0.phase == .reauthenticating }
        if !hasDetected || loginMayHaveEnded, !isRefreshing { refresh() }
        while isRefreshing, let task = refreshTask {
            await task.value
            // A superseded refresh hands over to the newer one; the same task twice is done.
            if refreshTask == task { break }
        }
    }

    /// The app became active, or the Settings window came forward (a login
    /// in a cmux terminal tab never makes the app inactive): re-detect if a
    /// login or logout ran in a tab meanwhile.
    public func appDidBecomeActive() {
        guard !pendingReauth.isEmpty else { return }
        for provider in pendingReauth { apply(.reauthEnded, to: provider) }
        pendingReauth.removeAll()
        refresh()
    }

    /// Starts the provider's own login now. Returns why it did not start
    /// (the row is busy, including Checking…), or nil. Callers that can wait
    /// use ``performReauthenticate(_:)``. A row already Re-authenticating
    /// opens the login again (its tab may be gone).
    @discardableResult
    public func reauthenticate(_ provider: AIProvider) -> String? {
        let state = row(provider)
        guard state.canReauthenticate else { return nil }
        guard state.phase == .idle || state.phase == .reauthenticating else { return AccountsStrings.errorBusy }
        if state.phase == .idle { apply(.reauthStarted, to: provider) }
        pendingReauth.insert(provider)
        guard services.reauthenticate(provider, plan: provider.reauthPlan) else { return nothingOpened(provider) }
        return nil
    }

    /// ``reauthenticate(_:)`` after detection settled, in the caller's task,
    /// so a busy row's refusal reaches the page, palette or CLI.
    public func performReauthenticate(_ provider: AIProvider) async -> String? {
        await settle()
        return reauthenticate(provider)
    }

    /// Runs the provider's own logout in a terminal tab; re-detects when the
    /// app becomes active again, like a re-authentication. Returns why
    /// nothing ran when no local pane could take the tab, or nil.
    @discardableResult
    public func signOut(_ provider: AIProvider) -> String? {
        guard row(provider).canSignOut, !row(provider).isBusy else { return nil }
        apply(.reauthStarted, to: provider)
        pendingReauth.insert(provider)
        guard services.reauthenticate(provider, plan: provider.signOutPlan) else { return nothingOpened(provider) }
        return nil
    }

    /// No local pane took the login or logout: the row is free again and
    /// says why, instead of waiting for a re-detect that never comes.
    private func nothingOpened(_ provider: AIProvider) -> String {
        pendingReauth.remove(provider)
        apply(.reauthFailed(AccountsStrings.errorNoLocalPane), to: provider)
        return AccountsStrings.errorNoLocalPane
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
        await settle()
        let state = row(provider)
        guard !state.isBusy else { return AccountsStrings.errorBusy }
        if let refusal = AccountsStrings.connectRefusal(state) { return refusal }
        apply(.connectStarted, to: provider)
        return await runConnect(provider, pasted: pasted)
    }

    private func runConnect(_ provider: AIProvider, pasted: String?) async -> String? {
        do {
            try await services.connect(provider, pasted: pasted)
            // A reload that fails keeps what the row showed; the next refresh adds the new account.
            let accounts = (try? await services.linkedAccounts()) ?? row(provider).linked
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
        await settle()
        guard !row(account.provider).isBusy else { return AccountsStrings.errorBusy }
        apply(.removeStarted(accountID: account.id), to: account.provider)
        // Not in the account list this screen last read.
        guard case .removing = row(account.provider).phase else { return AccountsStrings.errorStaleList }
        return await runRemove(account)
    }

    private func runRemove(_ account: LinkedAccount) async -> String? {
        do {
            try await services.remove(account)
            // A reload that fails keeps the row's other accounts (the reducer drops this one).
            let accounts = (try? await services.linkedAccounts()) ?? row(account.provider).linked
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
