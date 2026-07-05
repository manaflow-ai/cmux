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
final class HostAccountFlow: AccountFlow {
    private let coordinator: AuthCoordinator
    private let browserSignIn: HostBrowserSignInFlow
    private let featureFlags = CmuxFeatureFlags.shared
    @ObservationIgnored private var featureFlagsObserver: (any NSObjectProtocol)?
    private(set) var isProUpgradeAvailable: Bool

    init(coordinator: AuthCoordinator, browserSignIn: HostBrowserSignInFlow) {
        self.coordinator = coordinator
        self.browserSignIn = browserSignIn
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
        coordinator.isLoading || coordinator.isRestoringSession || browserSignIn.isSigningIn
    }

    var signInIsSlow: Bool {
        browserSignIn.signInIsSlow
    }

    func startSignIn() {
        browserSignIn.beginSignIn()
    }

    func openSignInInDefaultBrowser() {
        guard let url = browserSignIn.activeAttemptSignInURL else { return }
        NSWorkspace.shared.open(url)
    }

    func signOut() async {
        await browserSignIn.signOut()
    }

    func refreshCurrentUser() async {
        // The coordinator refreshes the user on sign-in and session restore;
        // there is no cheaper public refresh path. If the cached identity is
        // stale the user signs in again (full browser round trip).
    }

    func openProUpgrade() {
        ProUpgradePresenter.present()
    }

    private static func identity(from user: CMUXAuthUser?) -> AccountIdentity? {
        guard let user else { return nil }
        return AccountIdentity(
            id: user.id,
            displayName: user.displayName ?? "",
            email: user.primaryEmail ?? "",
            avatarURL: nil
        )
    }
}
