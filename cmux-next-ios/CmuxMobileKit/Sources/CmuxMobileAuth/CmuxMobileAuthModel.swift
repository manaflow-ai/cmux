#if os(iOS)
import AuthenticationServices
import CMUXAuthCore
import CmuxAuthRuntime
import CmuxMobileModel
import Foundation
import Observation
import OSLog
import StackAuth

private let authModelLog = Logger(subsystem: "dev.cmux.mobile", category: "auth")

/// The app's auth surface over the shared `AuthCoordinator` (Stack Auth:
/// Apple, Google, GitHub, email code). Views read observable state and call
/// the sign-in actions; nothing here touches UI.
@MainActor
@Observable
public final class CmuxMobileAuthModel {
    /// Sign-in method.
    public enum Provider: String, Sendable, Hashable, CaseIterable {
        case apple, google, github, email

        /// The provider's name as the welcome writes it.
        public var displayName: String {
            switch self {
            case .apple: "Apple"
            case .google: "Google"
            case .github: "GitHub"
            case .email: "email"
            }
        }
    }

    /// The signed-in user as the UI shows it.
    public struct User: Sendable, Hashable {
        public let id: String
        public let name: String
        public let email: String?

        public var initials: String {
            let parts = name.split(separator: " ").prefix(2)
            let letters = parts.compactMap(\.first).map(String.init).joined()
            return letters.isEmpty ? "?" : letters.uppercased()
        }
    }

    @ObservationIgnored let coordinator: AuthCoordinator?
    /// Stack's own token read (it refreshes a token older than 75 s) behind a
    /// stored token that was handed out at once; one at a time.
    @ObservationIgnored private var backgroundTokenRead: Task<Void, Never>?
    @ObservationIgnored let stack: StackClientApp?
    /// The `cmux-mobile-api` base URL (`CMUX_MOBILE_API_BASE`), when configured.
    @ObservationIgnored let apiBase: URL?
    /// Mock mode (DEBUG `CMUX_MOBILE_MOCK_AUTH=1`): signed in as a local user, no network.
    public let isMock: Bool
    private var mockSignedIn: Bool

    /// The provider whose flow is in flight (its button shows a spinner).
    public private(set) var busyProvider: Provider?
    /// A display-safe error for the welcome screen, `nil` on cancel.
    public var errorMessage: String?

    init(coordinator: AuthCoordinator?, stack: StackClientApp? = nil, apiBase: URL? = nil, isMock: Bool) {
        self.coordinator = coordinator
        self.stack = stack
        self.apiBase = apiBase
        self.isMock = isMock
        self.mockSignedIn = isMock
    }

    /// Builds the live model for this process. Non-DEBUG builds (Release,
    /// Production) use the production Stack project and its
    /// `https://cmux.com/auth/callback`, and never read launch overrides.
    /// Reads launch overrides from the environment (DEBUG only): `CMUX_MOBILE_CLEAR_AUTH=1` starts signed out,
    /// `CMUX_MOBILE_MOCK_AUTH=1` (or Settings → Developer → Mock) signs in a
    /// local mock user, and
    /// `CMUX_MOBILE_STACK_EMAIL` / `CMUX_MOBILE_STACK_PASSWORD` auto-login a Stack test account.
    public static func live(environment: [String: String], bundleIdentifier: String?) -> CmuxMobileAuthModel {
        #if DEBUG
        let isDebug = true
        if environment["CMUX_MOBILE_MOCK_AUTH"] == "1" || DeveloperOptions.mockData {
            let model = CmuxMobileAuthModel(coordinator: nil, isMock: true)
            model.mockSignedIn = environment["CMUX_MOBILE_CLEAR_AUTH"] != "1"
            return model
        }
        #else
        let isDebug = false
        #endif
        var launchEnvironment: [String: String] = [:]
        if isDebug, let email = environment["CMUX_MOBILE_STACK_EMAIL"], let password = environment["CMUX_MOBILE_STACK_PASSWORD"] {
            launchEnvironment["CMUX_UITEST_STACK_EMAIL"] = email
            launchEnvironment["CMUX_UITEST_STACK_PASSWORD"] = password
        }
        // A non-DEBUG staging build (project.yml TestFlightStaging) signs in to
        // the development Stack project: Info.plist CmuxMobileStackEnvironment.
        let stagingStack = Bundle.main.object(forInfoDictionaryKey: "CmuxMobileStackEnvironment") as? String == "development"
        let config = AuthConfig(environment: isDebug || stagingStack ? .development : .production)
        let tokenStore = KeychainStackTokenStore(
            service: KeychainStackTokenStore.serviceName(bundleIdentifier: bundleIdentifier),
            legacyProjectID: config.stack.projectId
        )
        // Built over StackClientApp directly so team creation goes to Stack
        // (the cmux web API base is a localhost dev server in DEBUG).
        let stack = StackClientApp(
            projectId: config.stack.projectId,
            publishableClientKey: config.stack.publishableClientKey,
            tokenStore: .custom(tokenStore),
            oauthBrowserSessionPrivacy: .shared
        )
        let defaults = UserDefaults.standard
        let coordinator = AuthCoordinator(
            client: StackAuthClient(stack: stack),
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "cmuxMobile.auth.hasTokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "cmuxMobile.auth.cachedUser"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "cmuxMobile.auth.selectedTeam"),
            anchor: AuthPresentationContextProvider(),
            config: config,
            launch: AuthLaunchOptions(
                clearAuthRequested: isDebug && environment["CMUX_MOBILE_CLEAR_AUTH"] == "1",
                mockDataEnabled: false,
                environment: launchEnvironment,
                includesDevAuth: isDebug
            )
        )
        coordinator.start()
        #if targetEnvironment(simulator) && !DEBUG
        // A simulator build of a shipping configuration (TestFlight, Production, Release) is how
        // the shipped app is verified end to end, and a simulator binary never runs on an iPhone.
        // Those configurations offer only email code and OAuth, which a Stack test account cannot
        // finish, so `CMUX_MOBILE_STACK_EMAIL` / `CMUX_MOBILE_STACK_PASSWORD` sign it in by
        // password against the build's own (production) Stack project, once, when signed out.
        // DEBUG builds use the coordinator's auto-login above instead.
        if let email = environment["CMUX_MOBILE_STACK_EMAIL"], !email.isEmpty,
           let password = environment["CMUX_MOBILE_STACK_PASSWORD"], !password.isEmpty {
            Task { @MainActor in
                await coordinator.awaitBootstrapped()
                guard !coordinator.isAuthenticated else { return }
                do { try await coordinator.signInWithPassword(email: email, password: password) } catch {
                    authModelLog.error("simulator test sign-in failed: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
        }
        #endif
        var serviceEnvironment = isDebug ? environment : [:]
        #if DEBUG && targetEnvironment(simulator)
        // A launch the system makes (a notification action wakes the app) carries no launch
        // variables: a rig's service override stays until a launch names another one.
        let storedOverride = "cmuxMobile.dev.apiBase"
        if let override = serviceEnvironment["CMUX_MOBILE_API_BASE"] {
            UserDefaults.standard.set(override.isEmpty ? nil : override, forKey: storedOverride)
        } else if let stored = UserDefaults.standard.string(forKey: storedOverride) {
            serviceEnvironment["CMUX_MOBILE_API_BASE"] = stored
        }
        #endif
        let apiBase = Self.apiBase(environment: serviceEnvironment, infoValue: Bundle.main.object(forInfoDictionaryKey: "CmuxMobileAPIBase") as? String, isDebug: isDebug)
        // Which backend this build talks to (public ids only, no tokens).
        authModelLog.info("Stack project \(config.stack.projectId, privacy: .public) (\(isDebug || stagingStack ? "development" : "production", privacy: .public)), callback \(config.magicLinkCallbackURL, privacy: .public), service \(apiBase?.host() ?? "none", privacy: .public)")
        return CmuxMobileAuthModel(coordinator: coordinator, stack: stack, apiBase: apiBase, isMock: false)
    }

    /// The `cmux-mobile-api` base URL: the `CMUX_MOBILE_API_BASE` launch override (DEBUG
    /// only), else the build's `CmuxMobileAPIBase` Info.plist value (set by the
    /// Production configuration), else the dev Worker in DEBUG builds.
    static func apiBase(environment: [String: String], infoValue: String?, isDebug: Bool) -> URL? {
        if let override = environment["CMUX_MOBILE_API_BASE"], let url = URL(string: override) { return url }
        if let infoValue, !infoValue.isEmpty, let url = URL(string: infoValue) { return url }
        return isDebug ? URL(string: "https://cmux-mobile-api-dev.debussy.workers.dev") : nil
    }

    /// Whether launch auth has resolved (a cached session counts immediately).
    public var isResolved: Bool {
        guard let coordinator else { return true }
        return coordinator.isAuthenticated || !coordinator.isRestoringSession
    }

    public var isSignedIn: Bool {
        coordinator?.isAuthenticated ?? mockSignedIn
    }

    public var user: User? {
        if isMock {
            #if DEBUG
            return mockSignedIn ? User(id: "mock", name: "Aziz Albahar", email: "aziz@example.com") : nil
            #else
            return nil
            #endif
        }
        guard let user = coordinator?.currentUser else { return nil }
        let name = user.displayName?.isEmpty == false ? user.displayName! : (user.primaryEmail ?? "cmux user")
        return User(id: user.id, name: name, email: user.primaryEmail)
    }

    /// Stack teams for the signed-in account (empty in mock mode, whose
    /// teams come from the sample store).
    public var teams: [AppStore.AccountTeam] {
        isMock ? [] : teamList.teams
    }

    /// The account's team list as it loads: setup shows a loading state, not
    /// Create Team, until it is `.loaded` (SPEC 7.1).
    public var teamList: TeamListState {
        var state = fetchedTeams
        state.published(coordinator?.availableTeams.map { AppStore.AccountTeam(id: $0.id, name: $0.displayName) } ?? [])
        return state
    }

    /// This model's own team fetch: the coordinator's list starts empty and
    /// tolerates a failed fetch silently, so it cannot tell "no teams" from
    /// "not loaded".
    private var fetchedTeams = TeamListState()
    @ObservationIgnored private var teamsUserID: String?

    /// Loads the signed-in account's teams (once per account; again after a
    /// failure). DEBUG mock mode takes `CMUX_MOBILE_MOCK_TEAMS_DELAY` seconds, to
    /// record the loading state.
    public func loadTeams() async {
        guard let user else {
            teamsUserID = nil
            fetchedTeams.reset()
            return
        }
        if teamsUserID != user.id {
            teamsUserID = user.id
            fetchedTeams.reset()
        } else if fetchedTeams.isLoaded {
            return
        }
        fetchedTeams.retry()
        if isMock {
            #if DEBUG
            if let delay = ProcessInfo.processInfo.environment["CMUX_MOBILE_MOCK_TEAMS_DELAY"].flatMap(Double.init), delay > 0 {
                // Recording pace, not synchronization: a slow team list.
                try? await Task.sleep(for: .seconds(delay))
            }
            fetchedTeams.fetched(AppStore.mock().teams.map { AppStore.AccountTeam(id: $0.id, name: $0.name) })
            #else
            // Mock auth exists only in DEBUG builds.
            fetchedTeams.fetched([])
            #endif
            return
        }
        guard let stack else { return }
        do {
            guard let account = try await stack.getUser(or: .returnNull) else { return }
            var list: [AppStore.AccountTeam] = []
            for team in try await account.listTeams() {
                list.append(AppStore.AccountTeam(id: team.id, name: await team.displayName))
            }
            guard teamsUserID == user.id else { return }
            fetchedTeams.fetched(list)
        } catch {
            guard teamsUserID == user.id else { return }
            authModelLog.error("team list failed: \(String(describing: type(of: error)), privacy: .public)")
            fetchedTeams.failed("Couldn't load your teams.")
        }
    }

    /// A team's members from Stack (`GET /team-member-profiles?team_id=`,
    /// client access), you first. The personal space is just you.
    public func teamMembers(teamID: String) async throws -> [TeamMember] {
        guard let user else { throw AuthError.unauthorized }
        let you = TeamMember(id: user.id, name: user.name, isYou: true)
        if teamID.hasPrefix("personal-") { return [you] }
        if isMock {
            #if DEBUG
            return TeamMember.list([(user.id, user.name), ("mock-2", "Lawrence Chen"), ("mock-3", "Austin Wang")], you: (user.id, user.name))
            #else
            return [you]
            #endif
        }
        guard let stack, let account = try await stack.getUser(or: .throw),
              let team = try await account.getTeam(id: teamID) else { throw AuthError.unauthorized }
        let profiles = try await team.listUsers().map { (userID: $0.id, displayName: $0.teamProfile.displayName) }
        return TeamMember.list(profiles, you: (user.id, user.name))
    }

    /// How the signed-in account can sign in: its linked OAuth providers and
    /// email code, password or passkey when Stack reports them enabled.
    public func signInMethods() async throws -> [SignInMethod] {
        guard let user else { throw AuthError.unauthorized }
        if isMock { return SignInMethod.methods(oauthProviderIDs: [], otpEmail: user.email, hasPassword: false, hasPasskey: false) }
        guard let stack, let account = try await stack.getUser(or: .throw) else { throw AuthError.unauthorized }
        let providers = await account.oauthProviders.map(\.id)
        let otp = await account.otpAuthEnabled
        let email = await account.primaryEmail
        return SignInMethod.methods(
            oauthProviderIDs: providers,
            otpEmail: otp ? email : nil,
            hasPassword: await account.hasPassword,
            hasPasskey: await account.passkeyAuthEnabled
        )
    }

    /// Retry after the team list failed to load.
    public func retryTeams() async {
        await loadTeams()
    }

    public var selectedTeamID: String? { coordinator?.resolvedTeamID }

    /// Whether interactive work disables the other sign-in buttons.
    public var isBusy: Bool { busyProvider != nil }

    /// Runs an OAuth provider flow. Cancel is silent; failures set `errorMessage`.
    public func signIn(with provider: Provider) async -> Bool {
        guard busyProvider == nil else { return false }
        busyProvider = provider
        errorMessage = nil
        defer { busyProvider = nil }
        if isMock {
            mockSignedIn = true
            return true
        }
        guard let coordinator else { return false }
        do {
            switch provider {
            case .apple: try await coordinator.signInWithApple()
            case .google: try await coordinator.signInWithGoogle()
            case .github: try await coordinator.signInWithGitHub()
            case .email: return false
            }
            return true
        } catch {
            errorMessage = Self.message(for: error, provider: provider)
            return false
        }
    }

    /// Sends a 6-digit code to `email`.
    public func sendCode(to email: String) async throws {
        if isMock { return }
        try await coordinator?.sendCode(to: email)
    }

    /// Verifies the 6-digit code; on success the session is live.
    public func verifyCode(_ code: String) async throws {
        if isMock {
            #if DEBUG
            guard code == "424242" else { throw AuthError.invalidCode }
            mockSignedIn = true
            return
            #else
            throw AuthError.invalidCode
            #endif
        }
        try await coordinator?.verifyCode(code)
    }

    /// Persists a team selection on Stack (cross-device). Best effort.
    public func selectTeam(_ id: String) async {
        try? await coordinator?.selectTeam(id: id)
    }

    /// Creates a team and selects it. Stack refuses team creation from the
    /// client (`client_team_creation_enabled` is off in both projects), so it
    /// goes through the cmux service (`POST /v1/teams`), which creates it with
    /// the project's server key; then the team list is read again from Stack.
    public func createTeam(named name: String) async throws -> AppStore.AccountTeam {
        if isMock { return AppStore.AccountTeam(id: "team-\(UUID().uuidString.prefix(8))", name: name) }
        guard let coordinator else { throw AuthError.unauthorized }
        guard let apiBase else { throw ServiceTeamCreation.Failure.unavailable }
        let creation = ServiceTeamCreation(apiBase: apiBase)
        let tokens = try await coordinator.currentTokens()
        let (data, response) = try await URLSession.shared.data(for: creation.request(accessToken: tokens.accessToken, name: name))
        let team = try creation.team(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        // The new membership, then the selection (best effort, as in Stack's own flow).
        await coordinator.refreshTeams()
        try? await coordinator.selectTeam(id: team.id)
        return team
    }

    /// Joins a team from a Stack invitation link (`...?code=...`) and refreshes
    /// the team list.
    public func joinTeam(inviteLink: String) async throws {
        let trimmed = inviteLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = URLComponents(string: trimmed)?.queryItems?.first { $0.name == "code" }?.value ?? trimmed
        guard !code.isEmpty else { throw AuthError.invalidCode }
        if isMock { return }
        guard let stack, let coordinator else { throw AuthError.unauthorized }
        try await stack.acceptTeamInvitation(code: code)
        await coordinator.refreshTeams()
    }

    /// Errors from invite-link creation.
    public enum InviteError: Error, Sendable {
        /// No `cmux-mobile-api` base URL is configured in this build.
        case serviceUnavailable
        case requestFailed
    }

    /// A Stack invitation URL for `teamID` from `POST /v1/teams/:teamId/invites`.
    public func inviteLink(teamID: String) async throws -> URL {
        guard let apiBase, let coordinator else { throw InviteError.serviceUnavailable }
        let tokens = try await coordinator.currentTokens()
        var request = URLRequest(url: apiBase.appending(path: "v1/teams/\(teamID)/invites"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let string = object["url"] as? String, let url = URL(string: string) else {
            throw InviteError.requestFailed
        }
        return url
    }

    /// The `cmux-mobile-api` base URL for live data (nil in mock mode or when unconfigured).
    public var apiBaseURL: URL? { isMock ? nil : apiBase }

    /// A current Stack access token (refreshed by the runtime when needed).
    /// `forceRefresh` mints a new one after the service rejected the last (401).
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let coordinator else { throw AuthError.unauthorized }
        return forceRefresh ? try await coordinator.forceRefreshAccessToken() : try await coordinator.accessToken()
    }

    /// The token for the mobile service and the Mac link, readable off the main
    /// actor. A stored token still valid for a minute goes out at once, without
    /// the main actor (busy drawing the first frames at launch, which held the
    /// first dial back 0.45 s) and without Stack's freshness rule (it refreshes
    /// over the network whenever the token is older than 75 s; that refresh
    /// still runs, in the background, so the next read has a new token).
    /// Otherwise, and with `forceRefresh` (the service answered 401), Stack's
    /// own read on the main actor, as before. verify/perf-latency.md.
    public nonisolated func serviceAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let stack, let stored = await stack.getStoredAccessToken(),
           AccessTokenExpiry(token: stored).isUsable() {
            // Not awaited: the main actor may be busy, and the token is good now.
            Task { @MainActor [weak self] in self?.refreshInBackground() }
            return stored
        }
        return try await accessToken(forceRefresh: forceRefresh)
    }

    /// Lets Stack refresh a stored token that was handed out as is (one at a time).
    private func refreshInBackground() {
        guard backgroundTokenRead == nil, let coordinator else { return }
        backgroundTokenRead = Task { [weak self] in
            _ = try? await coordinator.accessToken()
            self?.backgroundTokenRead = nil
        }
    }

    /// Runs before every sign-out while the session is still valid (the live
    /// layer stops pushes to this phone). Bounded: sign-out never waits long.
    @ObservationIgnored public var willSignOut: (@MainActor @Sendable () async -> Void)?

    /// Account deletion failures, in words for the user.
    public enum AccountDeletionError: Error, Sendable, Equatable {
        /// The mobile service could not forget the account's devices.
        case serviceData(String)
        /// The cmux account itself was not deleted (or not confirmed).
        case account(String)

        public var message: String {
            switch self {
            case .serviceData(let detail), .account(let detail): detail
            }
        }
    }

    /// Permanently deletes the account (App Store Guideline 5.1.1(v)):
    /// `purgeServiceData` first (the mobile service forgets this account's
    /// devices, push tokens and preferences, PROTOCOL.md `DELETE /v1/me`),
    /// then the Stack account through cmux's account deletion, as in the main
    /// cmux app, then a local sign-out.
    public func deleteAccount(purgeServiceData: (@MainActor () async throws -> Void)?) async throws {
        if isMock {
            await signOut()
            return
        }
        guard let coordinator else { throw AccountDeletionError.account("Not signed in.") }
        if let purgeServiceData {
            do {
                try await purgeServiceData()
            } catch {
                authModelLog.error("account deletion: service data purge failed: \(String(describing: error), privacy: .public)")
                throw AccountDeletionError.serviceData("Couldn't remove your devices from the cmux service. Check your connection and try again.")
            }
        }
        do {
            let result = try await coordinator.deleteAccount()
            authModelLog.info("account deleted (\(result == .completed ? "complete" : "cleanup pending", privacy: .public))")
        } catch let error as AccountDeletionRequestError {
            authModelLog.error("account deletion failed: \(String(describing: error), privacy: .public)")
            switch error {
            case .localTransportFailure:
                throw AccountDeletionError.account("You're offline. Connect to the internet and try again.")
            case .completionUnknown, .timedOut:
                throw AccountDeletionError.account("Couldn't confirm the account was deleted. Try again in a moment.")
            default:
                throw AccountDeletionError.account("Your account couldn't be deleted. Try again, or contact support from cmux.com.")
            }
        } catch {
            authModelLog.error("account deletion failed: \(String(describing: error), privacy: .public)")
            throw AccountDeletionError.account("Your account couldn't be deleted. Try again.")
        }
        let hook = willSignOut
        willSignOut = nil
        await signOut()
        willSignOut = hook
    }

    /// Local-first sign-out: the Stack session and its Keychain tokens (the
    /// coordinator) and this model's team list.
    public func signOut() async {
        if let willSignOut, !isMock {
            // At most 3 s: an unreachable service or a half-dead link never
            // holds sign-out (the work goes on in the background).
            await BoundedWait(.seconds(3)).run { await willSignOut() }
        }
        teamsUserID = nil
        fetchedTeams.reset()
        if isMock {
            mockSignedIn = false
            return
        }
        await coordinator?.signOut()
    }

    /// The welcome's message for a failed provider sign-in, naming the
    /// provider ("Couldn't sign in with Google. Try again."), or `nil` for a
    /// user cancel. Connection problems keep their own words.
    public static func message(for error: any Error, provider: Provider) -> String? {
        if let error = error as? ASAuthorizationError, error.code == .canceled { return nil }
        if error is CancellationError { return nil }
        switch AuthError(displaySafe: error) {
        case .cancelled: return nil
        case .offline: return "You're offline. Check your connection and try again."
        case .networkError: return "Couldn't reach the sign-in service. Check your connection and try again."
        case .timedOut: return "Sign-in timed out. Check your connection and try again."
        default: return "Couldn't sign in with \(provider.displayName). Try again."
        }
    }

    /// A user-facing message for an auth error, or `nil` for a user cancel.
    public static func message(for error: any Error) -> String? {
        if let error = error as? ASAuthorizationError, error.code == .canceled { return nil }
        if let authError = AuthError(displaySafe: error) {
            if authError == .cancelled { return nil }
            return authError.errorDescription
        }
        if error is CancellationError { return nil }
        return "Something went wrong. Try again."
    }
}
#endif
