import CmuxCloud
import AppKit
import CMUXAuthCore
import CmuxAuthRuntime
import CmuxSettingsUI
import Foundation
import Observation

/// Adapts the shared ``CmuxAuthRuntime/AuthCoordinator`` and the macOS
/// ``HostBrowserSignInFlow`` to the `CmuxSettingsUI` `AccountFlow` protocol so
/// the `AccountSection` can drive sign-in / sign-out / team selection without
/// depending on the auth packages.
///
/// A projection over the coordinator and browser flow. Upgrade entrypoints
/// remain available independently of remote rollout configuration.
@MainActor
@Observable
final class HostAccountFlow: AccountFlow, AccountSignInFlow {
    let coordinator: AuthCoordinator
    private let browserSignIn: HostBrowserSignInFlow
    var isProUpgradeAvailable: Bool { true }
    private var billingPlanRefresh = BillingPlanRefreshCoordinator()
    var billingPlanState: BillingPlanState { billingPlanRefresh.state }
    var isProActive: Bool { billingPlanState.isPro }
    var canManageBilling: Bool { billingPlanState.canManageBilling }
    /// The account whose plan is known, or nil while the plan is unknown.
    var billingPlanIdentityID: String? { billingPlanState.accountID }
    /// The team whose plan is known, or nil for a personal scope.
    var billingPlanTeamID: String? { billingPlanState.teamID }
    /// Whether `isProActive` is a real answer for the signed-in account.
    var hasLoadedBillingPlan: Bool {
        guard let billingPlanIdentityID else { return false }
        return billingPlanIdentityID == currentIdentity?.id
            && billingPlanState.teamID == confirmedTeamID
    }
    /// Whether upgrade controls may trust this flow's current Pro answer.
    /// Signed-out flows have no entitlement to load and are treated as known.
    var isProStatusKnownForUpgrade: Bool {
        !isWorkingOnAuth && (currentIdentity == nil || hasLoadedBillingPlan)
    }
    var teamObservationRevision: UInt64 = 0
    /// Pending selection is shared by Settings, the menu and socket actions.
    /// Cloud requests keep using the confirmed coordinator scope until success.
    var pendingTeamSelection: (requestID: UUID, teamID: String?)?
    var isSelectingTeam: Bool { coordinator.isSelectingTeam }
    /// A team create still waiting on the server, shown as the active team
    /// until the server answers. Switches and creates from every surface are
    /// refused until it finishes, since a later change would fail it.
    var pendingTeamCreate: PendingTeamCreate?
    /// Owns the optimistic create projection so a later create cannot clear
    /// it when the earlier coordinator request has already finished.
    var pendingTeamCreateRequestID: UUID?
    /// Invitations addressed to the signed-in user, refreshed on sign-in, by
    /// the poll and after every invitation action. Empty while signed out.
    var receivedInvitations: [CloudReceivedInvitation] = []
    @ObservationIgnored var receivedInvitationsPoll: Task<Void, Never>?
    @ObservationIgnored var receivedInvitationsLoaded = false
    var isCreatingTeam: Bool { coordinator.isCreatingTeam }

    init(coordinator: AuthCoordinator, browserSignIn: HostBrowserSignInFlow) {
        self.coordinator = coordinator
        self.browserSignIn = browserSignIn
        startCoordinatorObservation()
    }

    var currentIdentity: AccountIdentity? {
        _ = teamObservationRevision
        return Self.identity(from: coordinator.currentUser)
    }

    var availableTeams: [AccountTeamSummary] {
        _ = teamObservationRevision
        return coordinator.availableTeams.map { team in
            AccountTeamSummary(id: team.id, displayName: team.displayName, slug: team.slug)
        }
    }

    var selectedTeamID: String? {
        get {
            if let pendingTeamSelection { return pendingTeamSelection.teamID }
            return confirmedTeamID
        }
    }

    /// Cloud scope and persisted machine preferences follow confirmed authority.
    var confirmedTeamID: String? {
        _ = teamObservationRevision
        return coordinator.resolvedTeamID
    }

    var isWorkingOnAuth: Bool {
        _ = teamObservationRevision
        return coordinator.isLoading || coordinator.isRestoringSession || browserSignIn.isPresentingSignIn
    }

    var isAuthenticated: Bool {
        _ = teamObservationRevision
        return coordinator.isAuthenticated
    }

    var isPresentingSignIn: Bool {
        browserSignIn.isPresentingSignIn
    }

    var signInIsSlow: Bool {
        browserSignIn.signInIsSlow
    }

    var isCompletingSignIn: Bool {
        _ = teamObservationRevision
        return coordinator.isLoading || coordinator.isRestoringSession
    }

    var lastSignInFailure: AccountSignInModel.Failure? {
        guard let failure = browserSignIn.lastFailure else { return nil }
        switch failure {
        case .offline:
            return .offline
        case .networkError:
            return .network
        case .timedOut:
            return .timedOut
        case .serverError:
            return .server
        case .invalidCode, .invalidCallback:
            return .invalidLink
        case .browserSignInFailed:
            return .browserUnavailable
        case .unauthorized:
            return .unauthorized
        case .authFailure:
            return .rejected
        case .cancelled:
            return .cancelled
        }
    }

    func startSignIn() {
        browserSignIn.beginSignIn()
    }

    func startSignInForPane() -> URL? {
        browserSignIn.beginSignIn()
        return browserSignIn.activeAttemptSignInURL
    }

    var activeSignInURL: URL? {
        browserSignIn.activeAttemptSignInURL
    }

    /// Runs the same hosted Stack sign-in used by every UI entrypoint, while
    /// allowing socket callers to await a bounded result.
    func signIn(timeout: TimeInterval) async -> Bool {
        await browserSignIn.signIn(timeout: timeout)
    }

    /// Issues the manual hosted Stack sign-in URL through the same callback
    /// state owner as interactive sign-in.
    var manualSignInURL: URL {
        browserSignIn.manualSignInURL
    }

    /// Completes an external hosted Stack callback through the shared attempt.
    func handleCallbackURL(_ url: URL, delivery: AuthCallbackDelivery) async -> Bool {
        await browserSignIn.handleCallbackURL(url, delivery: delivery)
    }

    func openSignInInDefaultBrowser() {
        guard let url = browserSignIn.activeAttemptSignInURL else { return }
        _ = openSignInURLInDefaultBrowser(url)
    }

    func openSignInURLInDefaultBrowser(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func copySignInURL(_ url: URL) -> Bool {
        GhosttyApp.terminalPasteboard.writeString(
            url.absoluteString,
            to: .general
        )
    }

    func signOut() async {
        await browserSignIn.signOut()
        billingPlanRefresh.reset()
    }

    /// Set for the whole switch so sign-in gates show its progress instead of
    /// an idle Sign In button that would start a second attempt.
    private(set) var isSwitchingAccount = false
    @ObservationIgnored private var switchAttempt: Task<Bool, Never>?

    /// Signs out, then signs in again asking the hosted page to confirm the
    /// account. The browser may still hold a cmux session; the page's chooser
    /// offers "continue as" that account or a different one.
    func switchAccount() async {
        // Clicking again while a switch's window is open (it may be behind
        // other windows) replaces that attempt with a fresh window; the
        // sign-out already happened, so it is not repeated. A click while the
        // sign-out is still running is dropped: there is no window yet, and
        // starting one would race the sign-out.
        if isSwitchingAccount {
            if switchAttempt != nil {
                switchAttempt = browserSignIn.beginSignIn(selectAccount: true)
            }
            return
        }
        isSwitchingAccount = true
        defer {
            isSwitchingAccount = false
            switchAttempt = nil
        }
        await signOut()
        var attempt = browserSignIn.beginSignIn(selectAccount: true)
        switchAttempt = attempt
        // Stay switching until the newest attempt settles: a replaced one
        // ends early, cancelled, while its replacement is still open.
        while true {
            _ = await attempt.value
            guard let latest = switchAttempt, latest != attempt else { break }
            attempt = latest
        }
    }

    /// Socket variant of sign-out. The underlying sign-out continues if the
    /// caller's deadline expires, matching the browser flow contract.
    func signOut(timeout: TimeInterval) async {
        await browserSignIn.signOut(timeout: timeout)
        billingPlanRefresh.reset()
    }

    func refreshCurrentUser() async {
        // The coordinator refreshes the user on sign-in and session restore;
        // there is no cheaper public refresh path. If the cached identity is
        // stale the user signs in again (full browser round trip).
    }

    func refreshBillingPlan() async {
        _ = await refreshBillingPlanAndReportSuccess()
    }

    @discardableResult
    func refreshBillingPlanAndReportSuccess(
        tokenProvider: (() async throws -> (accessToken: String, refreshToken: String))? = nil,
        planFetcher: ((URL, String?, String?) async throws -> BillingPlanDetails)? = nil
    ) async -> Bool {
        guard coordinator.currentUser != nil, let identityID = currentIdentity?.id else {
            billingPlanRefresh.reset()
            return false
        }
        invalidateBillingPlanIfScopeChanged()
        let teamID = confirmedTeamID
        let scope = BillingPlanRefreshScope(accountID: identityID, teamID: teamID)
        let requestID = billingPlanRefresh.begin(scope: scope)

        let tokens: (accessToken: String, refreshToken: String)
        do {
            if let tokenProvider {
                tokens = try await tokenProvider()
            } else {
                tokens = try await coordinator.currentTokens()
            }
        } catch {
            invalidateBillingPlanIfScopeChanged()
            guard !Task.isCancelled else {
                billingPlanRefresh.discard(requestID, scope: scope)
                return false
            }
            guard billingPlanRefresh.isCurrent(requestID, scope: scope) else { return false }
            billingPlanRefresh.applyTransientFailure(requestID, scope: scope)
            return false
        }

        do {
            let endpoint = AuthEnvironment.apiBaseURL.appendingPathComponent("api/billing/plan")
            let url: URL
            if let teamID {
                guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                    throw URLError(.badURL)
                }
                components.queryItems = (components.queryItems ?? []) + [
                    URLQueryItem(name: "teamId", value: teamID)
                ]
                guard let scopedURL = components.url else {
                    throw URLError(.badURL)
                }
                url = scopedURL
            } else {
                url = endpoint
            }
            let details: BillingPlanDetails
            if let planFetcher {
                details = try await planFetcher(url, tokens.accessToken, tokens.refreshToken)
            } else {
                details = try await BillingPlanClient().fetch(
                    from: url,
                    accessToken: tokens.accessToken,
                    refreshToken: tokens.refreshToken
                )
            }
            invalidateBillingPlanIfScopeChanged()
            guard !Task.isCancelled else {
                billingPlanRefresh.discard(requestID, scope: scope)
                return false
            }
            guard billingPlanRefresh.isCurrent(requestID, scope: scope) else { return false }
            billingPlanRefresh.applySuccess(
                requestID,
                scope: scope,
                isPro: details.isPro,
                canManageBilling: details.canManageBilling
            )
            return true
        } catch {
            // A cancelled request (the panel went away) says nothing about the plan.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                billingPlanRefresh.discard(requestID, scope: scope)
                return false
            }
            invalidateBillingPlanIfScopeChanged()
            guard !Task.isCancelled else {
                billingPlanRefresh.discard(requestID, scope: scope)
                return false
            }
            guard billingPlanRefresh.isCurrent(requestID, scope: scope) else { return false }
            if error is BillingPlanClientError {
                // An explicit unauthenticated response invalidates the old
                // entitlement. Unlike a transient transport failure, it must
                // not leave a previously confirmed free plan eligible to show
                // the upgrade affordance.
                billingPlanRefresh.applyUnauthenticated(requestID, scope: scope)
                return false
            }
            billingPlanRefresh.applyTransientFailure(requestID, scope: scope)
            return false
        }
    }

    /// Drops a confirmed plan when the account or confirmed team scope changes.
    /// Pending team selections intentionally keep the old confirmed scope until
    /// the coordinator accepts the change.
    func invalidateBillingPlanIfScopeChanged() {
        billingPlanRefresh.invalidateIfScopeChanged(
            accountID: currentIdentity?.id,
            teamID: confirmedTeamID
        )
    }

    // `AccountFlow` (CmuxSettingsUI) cannot see `ProUpgradeSource`; its
    // parameterless calls come from the Settings account card.
    func openProUpgrade() {
        openProUpgrade(source: .settingsAccountCard)
    }

    func prefetchProUpgrade() {
        prefetchProUpgrade(source: .settingsAccountCard)
    }

    func openProUpgrade(source: ProUpgradeSource) {
        ProUpgradePresenter.present(source: source)
    }

    func prefetchProUpgrade(source: ProUpgradeSource) {
        ProUpgradePresenter.prefetch(source: source)
    }

    func openBillingPortal() {
        ProUpgradePresenter.presentBillingPortal()
    }

    private static func identity(from user: CMUXAuthUser?) -> AccountIdentity? {
        guard let user else { return nil }
        return AccountIdentity(
            id: user.id,
            displayName: user.displayName ?? "",
            email: user.primaryEmail ?? "",
            avatarURL: user.profileImageURL.flatMap(URL.init(string:))
        )
    }
}
