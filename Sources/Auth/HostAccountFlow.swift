import CMUXAuthCore
import CmuxSettingsUI
import Combine
import Foundation
import SwiftUI

/// Adapts the legacy `AuthManager` + `AuthSettingsStore` to the
/// package's `AccountFlow` protocol so the new `CmuxSettingsUI`
/// `AccountSection` can drive sign-in / sign-out / refresh without
/// depending on `CMUXAuthCore`.
///
/// Lifecycle: this is constructed once at app launch alongside the
/// `SettingsRuntime` and bridges `AuthManager`'s `@Published`
/// properties into `@Observable`-compatible state by subscribing in
/// `init`. The class itself is `@MainActor` because every read /
/// write hops to the main actor.
@MainActor
@Observable
final class HostAccountFlow: AccountFlow {
    private(set) var currentIdentity: AccountIdentity?
    private(set) var availableTeams: [AccountTeamSummary] = []
    var selectedTeamID: String? {
        didSet {
            guard selectedTeamID != oldValue else { return }
            authManager.selectedTeamID = selectedTeamID
        }
    }
    private(set) var isWorkingOnAuth: Bool = false

    private let authManager: AuthManager
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(authManager: AuthManager) {
        self.authManager = authManager
        self.currentIdentity = Self.identity(from: authManager.currentUser)
        self.availableTeams = authManager.availableTeams.map { team in
            AccountTeamSummary(id: team.id, displayName: team.displayName, slug: team.slug)
        }
        self.selectedTeamID = authManager.selectedTeamID
        self.isWorkingOnAuth = authManager.isLoading || authManager.isRestoringSession

        authManager.$currentUser
            .receive(on: DispatchQueue.main)
            .sink { [weak self] user in
                self?.currentIdentity = Self.identity(from: user)
            }
            .store(in: &cancellables)

        authManager.$availableTeams
            .receive(on: DispatchQueue.main)
            .sink { [weak self] teams in
                self?.availableTeams = teams.map { team in
                    AccountTeamSummary(id: team.id, displayName: team.displayName, slug: team.slug)
                }
            }
            .store(in: &cancellables)

        authManager.$selectedTeamID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                guard let self else { return }
                if self.selectedTeamID != newValue {
                    self.selectedTeamID = newValue
                }
            }
            .store(in: &cancellables)

        authManager.$isLoading
            .combineLatest(authManager.$isRestoringSession)
            .map { $0 || $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] busy in
                self?.isWorkingOnAuth = busy
            }
            .store(in: &cancellables)
    }

    func startSignIn() {
        authManager.beginSignIn()
    }

    func signOut() async {
        await authManager.signOut()
    }

    func refreshCurrentUser() async {
        // AuthManager.refreshSession is private; the public refresh
        // path is `beginSignIn()` (browser flow) for full re-auth.
        // For now refresh is a no-op; if the cached user is stale,
        // the user can sign in again. If we surface a public refresh
        // in AuthManager later, route it here.
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
