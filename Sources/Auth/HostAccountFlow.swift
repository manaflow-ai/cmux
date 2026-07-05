import AppKit
import CMUXAuthCore
import CmuxAuthRuntime
import CmuxSettingsUI
import Foundation

/// Adapts the shared ``CmuxAuthRuntime/AuthCoordinator`` and the macOS
/// ``HostBrowserSignInFlow`` to the `CmuxSettingsUI` `AccountFlow` protocol so
/// the `AccountSection` can drive sign-in / sign-out / team selection without
/// depending on the auth packages.
///
/// A pure projection: every property reads through the coordinator's (or the
/// browser flow's) `@Observable` storage, so SwiftUI views that read this
/// adapter in `body` re-render when the underlying auth state changes.
@MainActor
final class HostAccountFlow: AccountFlow {
    private let coordinator: AuthCoordinator
    private let browserSignIn: HostBrowserSignInFlow

    init(coordinator: AuthCoordinator, browserSignIn: HostBrowserSignInFlow) {
        self.coordinator = coordinator
        self.browserSignIn = browserSignIn
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

    var signInErrorMessage: String? {
        // Only while signed out: a stale failure from a prior attempt must not
        // shadow a successful sign-in. `lastFailure` is cleared on success and
        // never carries `.cancelled`, so its `errorDescription` is always a
        // user-facing message here.
        guard coordinator.currentUser == nil else { return nil }
        return browserSignIn.lastFailure?.errorDescription
    }

    func startSignIn() {
        browserSignIn.beginSignIn()
    }

    func openSignInInDefaultBrowser() {
        // Prefer the in-flight attempt's URL so the deep-link callback routes
        // back to that attempt; when no popup attempt is active (the signed-out
        // error/idle recovery path) fall back to a fresh default-browser URL
        // that still routes its callback home (issue #6015).
        let url = browserSignIn.activeAttemptSignInURL ?? browserSignIn.defaultBrowserSignInURL
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
