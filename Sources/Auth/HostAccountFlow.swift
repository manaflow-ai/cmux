import CmuxCloud
import CmuxProductAnalytics
import AppKit
import CMUXAuthCore
import CMUXMobileCore
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
    private(set) var billingPlanState = BillingPlanState.unknown
    var isProActive: Bool { billingPlanState.isPro }
    /// The signed-in account's tier, or nil while it is unknown.
    var planTier: CmuxPlanTier? { hasLoadedBillingPlan ? billingPlanState.tier : nil }
    /// The tier every upgrade entrypoint offers, or nil to hide them.
    var upgradeOffer: CmuxPlanTier? {
        CmuxPlanTier.upgradeOffer(isSignedIn: currentIdentity != nil, knownTier: planTier)
    }
    /// The Settings plan row renders for every tier; it picks its own copy
    /// and actions from ``planTier``. Menus gate on ``upgradeOffer`` instead.
    var isProUpgradeAvailable: Bool { true }
    var canManageBilling: Bool { billingPlanState.canManageBilling }
    /// The account whose plan is known, or nil while the plan is unknown.
    var billingPlanIdentityID: String? { billingPlanState.accountID }
    /// The most recent plan request. Only it may write, so an older request
    /// that finishes late cannot overwrite a newer answer.
    @ObservationIgnored private var billingPlanRequestID: UUID?
    /// The account and team the current plan answer belongs to.
    @ObservationIgnored private var billingPlanScope: String?
    /// Whether `isProActive` is a real answer for the signed-in account.
    var hasLoadedBillingPlan: Bool {
        guard let billingPlanIdentityID else { return false }
        return billingPlanIdentityID == currentIdentity?.id
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
    @ObservationIgnored let analytics: ProductAnalytics
    @ObservationIgnored var analyticsState = AccountAnalyticsState()

    init(
        coordinator: AuthCoordinator,
        browserSignIn: HostBrowserSignInFlow,
        analytics: ProductAnalytics = .app
    ) {
        self.coordinator = coordinator
        self.browserSignIn = browserSignIn
        self.analytics = analytics
        startCoordinatorObservation()
        syncAnalytics()
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
        case .rateLimited:
            return .rateLimited
        }
    }

    var isRetryingAfterRateLimit: Bool {
        browserSignIn.isRetryingAfterRateLimit
    }

    func startSignIn() {
        noteSignInStarted()
        browserSignIn.beginSignIn()
    }

    func startSignInForPane() -> URL? {
        noteSignInStarted()
        browserSignIn.beginSignIn()
        return browserSignIn.activeAttemptSignInURL
    }

    var activeSignInURL: URL? {
        browserSignIn.activeAttemptSignInURL
    }

    /// Runs the same hosted Stack sign-in used by every UI entrypoint, while
    /// allowing socket callers to await a bounded result.
    func signIn(timeout: TimeInterval) async -> Bool {
        noteSignInStarted()
        return await browserSignIn.signIn(timeout: timeout)
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

    var lastSignInFailureDetail: String? {
        browserSignIn.lastFailureDetail
    }

    func copyFailureDetail(_ detail: String) -> Bool {
        GhosttyApp.terminalPasteboard.writeString(detail, to: .general)
    }

    func signOut() async {
        // Captured before the sign-out so it joins the signed-in person.
        analytics.signedOut()
        await browserSignIn.signOut()
        billingPlanState = .unknown
        restoreAnalyticsIfStillSignedIn()
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
        noteSignInStarted()
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
        analytics.signedOut()
        await browserSignIn.signOut(timeout: timeout)
        billingPlanState = .unknown
        restoreAnalyticsIfStillSignedIn()
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
    func refreshBillingPlanAndReportSuccess() async -> Bool {
        guard coordinator.currentUser != nil, let identityID = currentIdentity?.id else {
            billingPlanState = .unknown
            return false
        }
        let requestID = UUID()
        billingPlanRequestID = requestID
        // Do not project the previous team/account's entitlement while this
        // request is in flight. Unknown keeps Cloud enabled until a verified
        // response arrives and avoids a false Free/Upgrade state. A refresh
        // of the same account and team keeps its answer, so a failed refresh
        // does not hide every upgrade entrypoint until the next change.
        let scope = "\(identityID):\(confirmedTeamID ?? "personal")"
        if billingPlanScope != scope {
            billingPlanState = .unknown
            billingPlanScope = scope
        }
        let tokens = try? await coordinator.currentTokens()

        do {
            let details = try await BillingPlanClient().fetch(
                from: AuthEnvironment.apiBaseURL.appendingPathComponent("api/billing/plan"),
                accessToken: tokens?.accessToken,
                refreshToken: tokens?.refreshToken
            )
            guard currentIdentity?.id == identityID, billingPlanRequestID == requestID else { return false }
            billingPlanState = billingPlanState.applyingSuccess(
                for: identityID,
                isPro: details.isPro,
                canManageBilling: details.canManageBilling,
                tier: details.tier
            )
            analytics.notePlan(accountID: identityID, isPaid: details.isPro)
            return true
        } catch {
            // A cancelled request (the panel went away) says nothing about the plan.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
            guard currentIdentity?.id == identityID, billingPlanRequestID == requestID else { return false }
            billingPlanState = billingPlanState.applyingFailure(for: identityID)
            return false
        }
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
