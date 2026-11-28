public import CmuxNextCodeRouter
public import Foundation
public import Observation

/// The Accounts screen: one ``AccountRowState`` per provider, fed by
/// detection and the user's buttons. Every operation is async
/// and runs off the main actor in the services; the model only applies
/// row events. Settings and onboarding share one model.
@MainActor
@Observable
public final class AccountsModel {
    public private(set) var rows: [AccountRowState]
    public private(set) var isRefreshing = false
    /// The provider whose paste sheet is open (a key or a Claude token).
    public var pasteTarget: AIProvider?
    /// Why the last team switch failed, until the next switch or refresh.
    public private(set) var teamError: String?
    @ObservationIgnored public let services: any AccountsServices
    /// Roles, team details and the create, rename and delete forms.
    public let teamsModel: AccountsTeamsModel
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Providers whose login was started here; re-detected on activation.
    @ObservationIgnored private var pendingReauth: Set<AIProvider> = []
    @ObservationIgnored private var openingReauth: Set<AIProvider> = []
    /// The latest refresh generation that could have observed the provider
    /// before its login tab opened. A refresh newer than this boundary may
    /// reconcile the completed login; older results are stale.
    @ObservationIgnored private var reauthCompletionGeneration: [AIProvider: Int] = [:]
    /// A detection has finished. Until then every row reads Checking… and
    /// refuses work, which the palette and CLI meet before the screen opens.
    @ObservationIgnored private var hasDetected = false

    public init(services: any AccountsServices) {
        self.services = services
        teamsModel = AccountsTeamsModel(services: services)
        rows = AIProvider.allCases.map(AccountRowState.init(provider:))
    }

    public func row(_ provider: AIProvider) -> AccountRowState {
        rows.first { $0.provider == provider } ?? AccountRowState(provider: provider)
    }

    /// Rows of one group, in catalog order. OpenCode Go has no local sign-in to show.
    public func rows(in group: AIProvider.Group) -> [AccountRowState] {
        rows.filter { $0.provider.group == group && $0.provider != .openCodeGo }
    }

    public var isSignedInToCmux: Bool { services.isSignedInToCmux }

    /// Detects every provider. A newer
    /// refresh supersedes an older one; stale results are dropped.
    public func refresh() {
        generation += 1
        let current = generation
        refreshTask?.cancel()
        teamError = nil
        isRefreshing = true
        apply(.detectionStarted)
        let services = services
        refreshTask = Task { [weak self] in
            let detecting = Task { await services.detect() }
            // Membership re-reads on its own; the team list updates when it lands.
            if let active = services.activeTeam { Task { await active.refresh() } }
            // Roles (and the open team's details) re-read on their own too.
            if let teamsModel = self?.teamsModel { Task { await teamsModel.reload() } }
            let found = await detecting.value
            guard let self, current == self.generation, !Task.isCancelled else { return }
            for detection in found where !self.openingReauth.contains(detection.provider)
                && (self.reauthCompletionGeneration[detection.provider].map({ current > $0 }) ?? true) {
                self.apply(.detected(detection), to: detection.provider)
            }
            self.hasDetected = true
            self.isRefreshing = false
        }
    }

    /// Makes `id` the active team. The App reloads what follows the team
    /// when the switch lands.
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
        let ended = pendingReauth.subtracting(openingReauth)
        guard !ended.isEmpty else { return }
        for provider in ended { apply(.reauthEnded, to: provider) }
        pendingReauth.subtract(ended)
        refresh()
    }

    /// Starts the provider's own login now. Returns why it did not start
    /// (the row is busy, including Checking…), or nil. Callers that can wait
    /// use ``performReauthenticate(_:)``. A row already Re-authenticating
    /// opens the login again (its tab may be gone).
    @discardableResult
    public func reauthenticate(_ provider: AIProvider) async -> String? {
        guard !openingReauth.contains(provider) else { return AccountsStrings.errorBusy }
        let state = row(provider)
        guard state.canReauthenticate else { return nil }
        guard state.phase == .idle || state.phase == .reauthenticating else { return AccountsStrings.errorBusy }
        if state.phase == .idle { apply(.reauthStarted, to: provider) }
        return await openProviderPlan(provider, plan: provider.reauthPlan)
    }

    /// ``reauthenticate(_:)`` after detection settled, in the caller's task,
    /// so a busy row's refusal reaches the page, palette or CLI.
    public func performReauthenticate(_ provider: AIProvider) async -> String? {
        await settle()
        return await reauthenticate(provider)
    }

    /// Runs the provider's own logout in a terminal tab; re-detects when the
    /// app becomes active again, like a re-authentication. Returns why
    /// nothing ran when no local pane could take the tab, or nil.
    @discardableResult
    public func signOut(_ provider: AIProvider) async -> String? {
        guard !openingReauth.contains(provider) else { return AccountsStrings.errorBusy }
        guard row(provider).canSignOut, !row(provider).isBusy else { return nil }
        apply(.reauthStarted, to: provider)
        return await openProviderPlan(provider, plan: provider.signOutPlan)
    }

    private func openProviderPlan(_ provider: AIProvider, plan: ReauthPlan) async -> String? {
        openingReauth.insert(provider)
        defer { openingReauth.remove(provider) }
        guard await services.reauthenticate(provider, plan: plan) else { return nothingOpened(provider) }
        apply(.reauthStarted, to: provider)
        pendingReauth.insert(provider)
        reauthCompletionGeneration[provider] = generation
        return nil
    }

    /// No local pane took the login or logout: the row is free again and
    /// says why, instead of waiting for a re-detect that never comes.
    private func nothingOpened(_ provider: AIProvider) -> String {
        pendingReauth.remove(provider)
        apply(.reauthFailed(AccountsStrings.errorNoLocalPane), to: provider)
        return AccountsStrings.errorNoLocalPane
    }

    /// Saves a pasted key to the Keychain; returns the failure text, or nil.
    @discardableResult
    public func saveKey(_ key: String, for provider: AIProvider) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AccountsStrings.errorNeedsPaste }
        // Detection trusts a saved key by its presence (it never reads the secret), so a
        // malformed key is never saved: it would read signed in and fail in the agent.
        guard CredentialResolver.isWellFormedKey(trimmed, for: provider) else { return AccountsStrings.errorInvalidFormat }
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
}
