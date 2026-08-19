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
    private let coordinator: AuthCoordinator
    private let browserSignIn: HostBrowserSignInFlow
    private let featureFlags = CmuxFeatureFlags.shared
    @ObservationIgnored private var featureFlagsObserver: (any NSObjectProtocol)?
    private(set) var isProUpgradeAvailable: Bool
    private(set) var isProActive = false
    private(set) var canManageBilling = false
    /// The backend environment the composition root actually resolved at
    /// startup (threaded in rather than re-read from defaults, so the value
    /// always describes the running process even after the user flips the
    /// picker).
    private let activeBackendEnvironmentOverride: CMUXBackendEnvironmentOverride
    /// The persisted selection, applied at next launch. Stored (not
    /// re-loaded per read) so `@Observable` re-renders the Settings card
    /// when ``selectBackendEnvironment(_:)`` changes it.
    private var pendingBackendEnvironmentOverride: CMUXBackendEnvironmentOverride
    let backendEnvironmentPinnedByLaunchEnvironment: Bool
    @ObservationIgnored private let backendEnvironmentDefaults: UserDefaults

    init(
        coordinator: AuthCoordinator,
        browserSignIn: HostBrowserSignInFlow,
        activeBackendEnvironmentOverride: CMUXBackendEnvironmentOverride = .production,
        backendEnvironmentPinnedByLaunchEnvironment: Bool = false,
        backendEnvironmentDefaults: UserDefaults = .standard
    ) {
        self.coordinator = coordinator
        self.browserSignIn = browserSignIn
        self.activeBackendEnvironmentOverride = activeBackendEnvironmentOverride
        self.pendingBackendEnvironmentOverride = CMUXBackendEnvironmentOverride.load(
            from: backendEnvironmentDefaults
        )
        self.backendEnvironmentPinnedByLaunchEnvironment = backendEnvironmentPinnedByLaunchEnvironment
        self.backendEnvironmentDefaults = backendEnvironmentDefaults
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
        coordinator.isLoading || coordinator.isRestoringSession || browserSignIn.isPresentingSignIn
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

    func signOut() async {
        await browserSignIn.signOut()
        isProActive = false
        canManageBilling = false
    }

    /// Socket variant of sign-out. The underlying sign-out continues if the
    /// caller's deadline expires, matching the browser flow contract.
    func signOut(timeout: TimeInterval) async {
        await browserSignIn.signOut(timeout: timeout)
        isProActive = false
        canManageBilling = false
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

    /// The picker shows for verified team members, always in DEBUG builds,
    /// and whenever the persisted or active environment is already
    /// non-production, so switching back to production is always possible.
    var backendEnvironmentSwitcherVisible: Bool {
        if Self.isDebugBuild { return true }
        if pendingBackendEnvironmentOverride != .production { return true }
        if activeBackendEnvironmentOverride != .production { return true }
        return CMUXBackendEnvironmentSwitchGate.allows(coordinator.currentUser)
    }

    var activeBackendEnvironment: AccountBackendEnvironment {
        Self.accountBackendEnvironment(from: activeBackendEnvironmentOverride)
    }

    var pendingBackendEnvironment: AccountBackendEnvironment {
        Self.accountBackendEnvironment(from: pendingBackendEnvironmentOverride)
    }

    func selectBackendEnvironment(_ value: AccountBackendEnvironment) {
        let override = Self.backendEnvironmentOverride(from: value)
        guard override != pendingBackendEnvironmentOverride else { return }
        override.store(in: backendEnvironmentDefaults)
        pendingBackendEnvironmentOverride = override
    }

    /// Relaunches through the same seams the app already trusts: the
    /// Sparkle-updater session persist (``AppDelegate/persistSessionForUpdateRelaunch()``)
    /// followed by the `open -n` + terminate mechanism of
    /// ``HostSettingsActions/restartApp()``. The new instance resolves the
    /// pending override at startup and
    /// ``MacAuthComposition/detectAuthProjectSwitch(resolvedProjectID:buildDefaultProjectID:defaults:)``
    /// wipes the stale cross-project session.
    func relaunchToApplyBackendEnvironment() {
        AppDelegate.shared?.persistSessionForUpdateRelaunch()
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Tagged dev builds bake `CMUX_*` origins into their LSEnvironment via
    /// `scripts/reload.sh`; those explicit env layers outrank the persisted
    /// override everywhere in `AuthEnvironment`, so the Settings card shows
    /// a "pinned" note instead of pretending the picker applies. Computed in
    /// the host because the package deliberately never reads ProcessInfo.
    nonisolated static func launchEnvironmentPinsBackendEnvironment(
        _ environment: [String: String]
    ) -> Bool {
        let pinningKeys = [
            "CMUX_WWW_ORIGIN",
            "CMUX_API_BASE_URL",
            "CMUX_AUTH_ENVIRONMENT",
            "CMUX_VM_API_BASE_URL",
        ]
        return pinningKeys.contains { key in
            guard let value = environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !value.isEmpty
        }
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

    private static func backendEnvironmentOverride(
        from value: AccountBackendEnvironment
    ) -> CMUXBackendEnvironmentOverride {
        switch value {
        case .production: .production
        case .staging: .staging
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
