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
/// A projection over the coordinator, browser flow, and feature flags. The
/// stored Pro availability value forwards feature-flag notifications so
/// SwiftUI views that read this adapter in `body` re-render when remote flags
/// change after Settings is already open.
@MainActor
@Observable
final class HostAccountFlow: AccountFlow, AccountSignInFlow {
    /// The live auth graph pieces. `var` because a live backend-environment
    /// switch replaces them via
    /// ``rebind(coordinator:browserSignIn:activeBackendEnvironmentSelection:backendEnvironmentBuildLane:)``
    /// while this flow object (and the Settings UI observing it) survives.
    private var coordinator: AuthCoordinator
    private var browserSignIn: HostBrowserSignInFlow
    private let featureFlags = CmuxFeatureFlags.shared
    @ObservationIgnored private var featureFlagsObserver: (any NSObjectProtocol)?
    private(set) var isProUpgradeAvailable: Bool
    private(set) var isProActive = false
    private(set) var canManageBilling = false
    /// The backend selection the composition root actually resolved
    /// (threaded in rather than re-read from defaults, so the value always
    /// describes the running graph). Updated by ``rebind`` after a live
    /// switch. Named to avoid colliding with the `AccountFlow` protocol's
    /// package-mirror ``activeBackendEnvironmentSelection``.
    private(set) var activeBackendEnvironmentHostSelection: CMUXBackendEnvironmentSelection
    /// The build's own lane, classified once per process from the launch
    /// environment (the explicit choice is ignored for classification).
    /// Threaded through ``rebind`` for consistency even though a live
    /// process's lane never changes.
    private(set) var hostBackendEnvironmentBuildLane: CMUXBackendEnvironmentBuildLane
    /// The persisted selection. With the live switch this only diverges from
    /// the active value if another writer changed the defaults key outside
    /// the transaction; ``rebind`` re-reads it so the UI converges.
    private var pendingBackendEnvironmentSelection: CMUXBackendEnvironmentSelection
    @ObservationIgnored private let backendEnvironmentDefaults: UserDefaults
    /// The live-switch engine. Attached once by `MacAuthComposition`'s
    /// startup initializer and kept stable across switches.
    private var backendEnvironmentSwitchController: MacBackendEnvironmentSwitchController?
    /// Presents the "signing out on staging returns you to Production"
    /// confirmation. Injected (production: an NSAlert presenter; tests: a
    /// fake) so the interception at the ``signOut()`` choke point is
    /// testable without AppKit. Only consulted while the active selection is
    /// EXPLICIT staging (a staging-lane rig keeps plain sign-outs); the
    /// socket variant ``signOut(timeout:)`` skips it.
    @ObservationIgnored private let confirmStagingSignOut: @MainActor () async -> Bool

    init(
        coordinator: AuthCoordinator,
        browserSignIn: HostBrowserSignInFlow,
        activeBackendEnvironmentSelection: CMUXBackendEnvironmentSelection =
            .lane(resolves: .production),
        backendEnvironmentBuildLane: CMUXBackendEnvironmentBuildLane = .production,
        backendEnvironmentDefaults: UserDefaults = .standard,
        confirmStagingSignOut: @escaping @MainActor () async -> Bool = { true }
    ) {
        self.coordinator = coordinator
        self.browserSignIn = browserSignIn
        self.activeBackendEnvironmentHostSelection = activeBackendEnvironmentSelection
        self.hostBackendEnvironmentBuildLane = backendEnvironmentBuildLane
        self.pendingBackendEnvironmentSelection = Self.persistedSelection(
            in: backendEnvironmentDefaults,
            lane: backendEnvironmentBuildLane
        )
        self.backendEnvironmentDefaults = backendEnvironmentDefaults
        self.confirmStagingSignOut = confirmStagingSignOut
        isProUpgradeAvailable = featureFlags.isProUpgradeUIEnabled
        featureFlagsObserver = NotificationCenter.default.addObserver(
            forName: .cmuxFeatureFlagsDidChange,
            object: featureFlags,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isProUpgradeAvailable = CmuxFeatureFlags.shared.isProUpgradeUIEnabled
            }
        }
    }

    deinit {
        if let featureFlagsObserver {
            NotificationCenter.default.removeObserver(featureFlagsObserver)
        }
    }

    var currentIdentity: AccountIdentity? {
        Self.identity(from: coordinator.currentUser)
    }

    var availableTeams: [AccountTeamSummary] {
        coordinator.availableTeams.map { team in
            AccountTeamSummary(id: team.id, displayName: team.displayName, slug: team.slug)
        }
    }

    var selectedTeamID: String? {
        get { coordinator.selectedTeamID }
        set { coordinator.selectedTeamID = newValue }
    }

    var isWorkingOnAuth: Bool {
        coordinator.isLoading
            || coordinator.isRestoringSession
            || browserSignIn.isPresentingSignIn
            || (backendEnvironmentSwitchController?.isSwitching ?? false)
    }

    var isAuthenticated: Bool {
        coordinator.isAuthenticated
    }

    var isPresentingSignIn: Bool {
        browserSignIn.isPresentingSignIn
    }

    var signInIsSlow: Bool {
        browserSignIn.signInIsSlow
    }

    var isCompletingSignIn: Bool {
        coordinator.isLoading || coordinator.isRestoringSession
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
    func handleCallbackURL(_ url: URL) async -> Bool {
        await browserSignIn.handleCallbackURL(url)
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

    /// The ONE interactive sign-out choke point (Settings card, sidebar
    /// popover, command palette all land here). Sign-out is
    /// per-environment, keyed on the SELECTION: only EXPLICIT staging
    /// intercepts (a staging-LANE rig keeps today's plain sign-out, as does
    /// explicit production). The intercepted path first asks the injected
    /// confirmation ("this returns you to Production"), then runs the REAL
    /// sign-out under the current (staging) defaults — so the revocation
    /// hits staging — and chains a switch back to the build's LANE, which
    /// restores its parked session (a lane target never gates, so the chain
    /// can't prompt).
    func signOut() async {
        guard activeBackendEnvironmentHostSelection == .explicit(.staging) else {
            await signOutDirect()
            return
        }
        guard await confirmStagingSignOut() else { return }
        await signOutDirect()
        await returnToLaneAfterSignOut()
    }

    /// Socket variant of sign-out (`auth.sign_out`). Stays non-interactive:
    /// it SKIPS the staging confirmation (a modal or a refusal would break
    /// automation and strand staging) but chains the same return-to-lane
    /// switch, reported to the caller through the returned flag. The
    /// underlying sign-out continues if the caller's deadline expires,
    /// matching the browser flow contract.
    /// - Returns: Whether the sign-out chained a switch back to the build's
    ///   lane (the socket payload's `returned_to_lane`, and — kept for
    ///   automation compatibility — `returned_to_production`).
    @discardableResult
    func signOut(timeout: TimeInterval) async -> Bool {
        let chainsBackToLane = activeBackendEnvironmentHostSelection == .explicit(.staging)
        await browserSignIn.signOut(timeout: timeout)
        isProActive = false
        canManageBilling = false
        guard chainsBackToLane else { return false }
        return await returnToLaneAfterSignOut()
    }

    /// The plain sign-out chain with no environment interception: the
    /// browser flow's full teardown plus the Pro-state reset. Used directly
    /// by production sign-out, by the confirmed staging sign-out, and as the
    /// switch transaction's `signOutEstablishedSession` step (which must
    /// never re-enter the staging confirmation).
    func signOutDirect() async {
        await browserSignIn.signOut()
        isProActive = false
        canManageBilling = false
    }

    /// Chain the per-environment sign-out back to the build's LANE through
    /// the SAME switch transaction as the picker. Parking the just-signed-out
    /// coordinator is a safe no-op, and a lane restore never gates or
    /// prompts. On an unpinned Release build the lane is production, so this
    /// is the identical key-removal behavior the chain always had.
    /// - Returns: Whether the switch chain actually ran.
    @discardableResult
    private func returnToLaneAfterSignOut() async -> Bool {
        guard let backendEnvironmentSwitchController else { return false }
        await backendEnvironmentSwitchController.switchEnvironment(
            to: .lane(resolves: hostBackendEnvironmentBuildLane.resolvedEnvironment)
        )
        return true
    }

    func refreshCurrentUser() async {
        // The coordinator refreshes the user on sign-in and session restore;
        // there is no cheaper public refresh path. If the cached identity is
        // stale the user signs in again (full browser round trip).
    }

    func refreshBillingPlan() async {
        guard coordinator.currentUser != nil else {
            isProActive = false
            canManageBilling = false
            return
        }
        var request = URLRequest(url: AuthEnvironment.apiBaseURL.appendingPathComponent("api/billing/plan"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let tokens = try? await coordinator.currentTokens() {
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                isProActive = false
                canManageBilling = false
                return
            }
            let decoded = try JSONDecoder().decode(BillingPlanResponse.self, from: data)
            isProActive = decoded.isPro
            canManageBilling = decoded.billingManagement == .stripe
        } catch {
            isProActive = false
            canManageBilling = false
        }
    }

    func openProUpgrade() {
        ProUpgradePresenter.present()
    }

    func prefetchProUpgrade() {
        ProUpgradePresenter.prefetch()
    }

    func openBillingPortal() {
        ProUpgradePresenter.presentBillingPortal()
    }

    // MARK: - Backend environment switcher

    /// STRICT full-picker gate: a verified team member or a DEBUG build,
    /// nothing else. Switch-back reachability for everyone else is handled
    /// by the package's recovery visibility tier
    /// (`AccountFlow.backendEnvironmentCardVisibility`), not by widening
    /// this gate.
    var backendEnvironmentPickerAllowed: Bool {
        if Self.isDebugBuild { return true }
        return CMUXBackendEnvironmentSwitchGate.allows(coordinator.currentUser)
    }

    var activeBackendEnvironment: AccountBackendEnvironment {
        Self.accountBackendEnvironment(
            from: activeBackendEnvironmentHostSelection.resolvedEnvironment
        )
    }

    var pendingBackendEnvironment: AccountBackendEnvironment {
        Self.accountBackendEnvironment(
            from: pendingBackendEnvironmentSelection.resolvedEnvironment
        )
    }

    /// The package mirror of the active selection (`.buildLane` for the
    /// lane, `.production`/`.staging` for an explicit choice). Drives the
    /// picker's selected option, the interception-aware recovery routing,
    /// and the lane-target confirm copy.
    var activeBackendEnvironmentSelection: AccountBackendEnvironmentSelection {
        Self.accountSelection(from: activeBackendEnvironmentHostSelection)
    }

    /// The package mirror of the build lane, powering the option-set rule
    /// (two positions on a production lane, three otherwise) and the
    /// "Build lane (…)" labels.
    var backendEnvironmentBuildLane: AccountBackendEnvironmentBuildLane {
        Self.accountBuildLane(from: hostBackendEnvironmentBuildLane)
    }

    var backendEnvironmentSwitchPhase: AccountBackendEnvironmentSwitchPhase {
        switch backendEnvironmentSwitchController?.phase {
        case .none, .idle: .idle
        case .parking: .parking
        case .retargeting: .retargeting
        case .establishing: .establishing
        case .reverting: .reverting
        case .finished(let outcome): .finished(Self.accountOutcome(from: outcome))
        }
    }

    /// Runs the live transactional switch (park under the old defaults,
    /// quiesce, store, rebuild, establish) through the attached
    /// ``MacBackendEnvironmentSwitchController``. The package's selection
    /// mirror maps host-side: `.buildLane` is the lane; on a PRODUCTION lane
    /// the picker's "Production" option also maps to the lane (clearChoice —
    /// the key stays absent, preserving the pre-tri-state semantics of the
    /// two-position picker), while on any other lane "Production" is the
    /// explicit wholesale choice.
    func applyBackendEnvironment(_ value: AccountBackendEnvironmentSelection) async {
        guard let backendEnvironmentSwitchController else { return }
        await backendEnvironmentSwitchController.switchEnvironment(
            to: hostSelection(from: value)
        )
    }

    /// Map the package's picker option to the host selection the transaction
    /// runs on. See ``applyBackendEnvironment(_:)`` for the production-lane
    /// "Production"→lane rule.
    private func hostSelection(
        from value: AccountBackendEnvironmentSelection
    ) -> CMUXBackendEnvironmentSelection {
        let lane = CMUXBackendEnvironmentSelection.lane(
            resolves: hostBackendEnvironmentBuildLane.resolvedEnvironment
        )
        switch value {
        case .buildLane:
            return lane
        case .production:
            return hostBackendEnvironmentBuildLane == .production ? lane : .explicit(.production)
        case .staging:
            return .explicit(.staging)
        }
    }

    func resetBackendEnvironmentSwitchPhase() {
        backendEnvironmentSwitchController?.reset()
    }

    // MARK: - Backend environment switch steps

    /// How long the switch's inline sign-in prompt waits before resolving
    /// `nil`. Matches `HostBrowserSignInFlow`'s browser-attempt timeout (the
    /// attempt's own deadline fires first and records `.timedOut`, so a
    /// timeout classifies as a failure, not a cancel).
    static let backendSwitchSignInPromptTimeout: TimeInterval = 10 * 60

    /// The transaction's `parkSession` step: the browser flow's park (which
    /// detaches the coordinator session, leaving its token slot untouched)
    /// plus the same Pro-state reset sign-out performs.
    func parkSession() async {
        await browserSignIn.parkSession()
        isProActive = false
        canManageBilling = false
    }

    /// The transaction's `awaitRestoredUser` step: await the CURRENT
    /// (post-rebind) coordinator's launch restore and report the user it
    /// restored from the target's parked slot. `coordinator` is read at call
    /// time, so after `rebind` this resolves the rebuilt graph.
    func awaitRestoredUser() async -> CMUXAuthUser? {
        await coordinator.awaitBootstrapped()
        return coordinator.currentUser
    }

    /// The transaction's `promptSignIn` step: run the same hosted-browser
    /// sign-in as every other entrypoint (against the CURRENT rebound
    /// graph), bounded by ``backendSwitchSignInPromptTimeout``. Returns the
    /// signed-in user, or `nil` on cancel / failure / timeout — classified
    /// afterwards by ``backendSwitchSignInPromptFailure()``.
    func promptSignInForBackendSwitch() async -> CMUXAuthUser? {
        let signedIn = await browserSignIn.signIn(timeout: Self.backendSwitchSignInPromptTimeout)
        guard signedIn else {
            // The deadline resolves without cancelling the underlying
            // attempt; end it so a stale popup can't complete into the
            // environment the transaction is about to revert away from.
            browserSignIn.cancelSignIn()
            return nil
        }
        return coordinator.currentUser
    }

    /// The transaction's `cancelSignInPrompt` step (`requestRevert()`).
    func cancelBackendSwitchSignInPrompt() {
        browserSignIn.cancelSignIn()
    }

    /// Classify a `nil` ``promptSignInForBackendSwitch()``: no recorded
    /// failure means the user backed out (cancel); anything else is a
    /// failure. Drives the revert reason shown in the outcome note.
    func backendSwitchSignInPromptFailure()
        -> BackendEnvironmentSwitchTransaction.SignInPromptFailure {
        browserSignIn.lastFailure == nil ? .cancelled : .failed
    }

    /// Attach the live-switch engine. Called once from `MacAuthComposition`'s
    /// startup initializer (after both objects exist; the controller's steps
    /// reference this flow weakly, so neither owns the other strongly in a
    /// cycle).
    func attachBackendEnvironmentSwitchController(
        _ controller: MacBackendEnvironmentSwitchController
    ) {
        backendEnvironmentSwitchController = controller
    }

    /// Adopt the freshly built auth graph after a live backend-environment
    /// switch, keeping this flow object (and everything observing it) alive.
    /// Re-reads the persisted selection so active and pending converge on
    /// the committed choice.
    func rebind(
        coordinator: AuthCoordinator,
        browserSignIn: HostBrowserSignInFlow,
        activeBackendEnvironmentSelection: CMUXBackendEnvironmentSelection,
        backendEnvironmentBuildLane: CMUXBackendEnvironmentBuildLane
    ) {
        self.coordinator = coordinator
        self.browserSignIn = browserSignIn
        self.activeBackendEnvironmentHostSelection = activeBackendEnvironmentSelection
        self.hostBackendEnvironmentBuildLane = backendEnvironmentBuildLane
        pendingBackendEnvironmentSelection = Self.persistedSelection(
            in: backendEnvironmentDefaults,
            lane: backendEnvironmentBuildLane
        )
    }

    /// The selection the defaults currently persist: an explicit choice when
    /// the tri-state key holds a recognized value, otherwise the lane.
    private nonisolated static func persistedSelection(
        in defaults: UserDefaults,
        lane: CMUXBackendEnvironmentBuildLane
    ) -> CMUXBackendEnvironmentSelection {
        CMUXBackendEnvironmentOverride.explicitChoice(from: defaults)
            .map { .explicit($0) }
            ?? .lane(resolves: lane.resolvedEnvironment)
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func accountBackendEnvironment(
        from override: CMUXBackendEnvironmentOverride
    ) -> AccountBackendEnvironment {
        switch override {
        case .production: .production
        case .staging: .staging
        }
    }

    private static func accountSelection(
        from selection: CMUXBackendEnvironmentSelection
    ) -> AccountBackendEnvironmentSelection {
        switch selection {
        case .lane: .buildLane
        case .explicit(.production): .production
        case .explicit(.staging): .staging
        }
    }

    private static func accountBuildLane(
        from lane: CMUXBackendEnvironmentBuildLane
    ) -> AccountBackendEnvironmentBuildLane {
        switch lane {
        case .production: .production
        case .staging: .staging
        case .custom(let label): .custom(label: label)
        }
    }

    private static func accountOutcome(
        from outcome: BackendEnvironmentSwitchTransaction.Outcome
    ) -> AccountBackendEnvironmentSwitchOutcome {
        switch outcome {
        case .switched: .switched
        case .reverted(.signInCancelled): .reverted(.signInCancelled)
        case .reverted(.signInFailed): .reverted(.signInFailed)
        case .reverted(.notEligible): .reverted(.notEligible)
        }
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

private struct BillingPlanResponse: Decodable {
    let isPro: Bool
    let billingManagement: BillingManagement?
}

private enum BillingManagement: String, Decodable {
    case stripe
    case external
    case none
}
