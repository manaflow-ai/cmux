public import AppKit
public import CMUXAuthCore
public import CmuxAuthRuntime
import Foundation
public import Observation

/// Stack Auth for cmux-next, composed from the kept `CmuxAuthRuntime`
/// library exactly as the old app did (MacAuthComposition): the Keychain
/// token store under the existing service name with the file fallback, the
/// same `cmux.auth.*` defaults keys, `AuthCoordinator` for restore and
/// tokens, and `HostBrowserSignInFlow` for the hosted browser sign-in.
/// Tokens are never cached here; every API call asks the coordinator.
@MainActor @Observable
public final class CloudAuth {
    public let configuration: CloudConfiguration
    @ObservationIgnored public let coordinator: AuthCoordinator
    @ObservationIgnored public let browserSignIn: HostBrowserSignInFlow
    @ObservationIgnored private let callbackRouter: AuthCallbackRouter

    public var isSignedIn: Bool { coordinator.isAuthenticated }
    public var isRestoring: Bool { coordinator.isRestoringSession }
    public var user: CMUXAuthUser? { coordinator.currentUser }
    /// `RestrictToManagedTeam` with `ManagedTeam` (enterprise P17-3): the
    /// only team this device may use, or nil. The account's other teams are
    /// neither listed nor selectable, and without that team there is none.
    public var managedTeamID: String?
    public var teams: [CMUXAuthTeam] { Self.allowedTeams(coordinator.availableTeams, managed: managedTeamID) }
    public var teamID: String? {
        Self.allowedTeamID(resolved: coordinator.resolvedTeamID, available: coordinator.availableTeams.map(\.id), managed: managedTeamID)
    }

    /// The account's teams this device may use.
    nonisolated static func allowedTeams(_ teams: [CMUXAuthTeam], managed: String?) -> [CMUXAuthTeam] {
        guard let managed else { return teams }
        return teams.filter { $0.id == managed }
    }

    /// The team API calls use: the resolved one, or only the managed one
    /// (when the account belongs to it) while the device is restricted.
    nonisolated static func allowedTeamID(resolved: String?, available: [String], managed: String?) -> String? {
        guard let managed else { return resolved }
        return available.contains(managed) ? managed : nil
    }

    /// The variables that choose a debug build's sign-in account. main strips
    /// inherited CMUX_* variables before anything reads them (LaunchIdentity),
    /// so these are captured first and reach CloudAuth only, never a child.
    nonisolated static let authLaunchKeyNames: Set<String> = [
        "CMUX_AUTH_CREDENTIALS_FILE", "CMUX_DEV_AUTH_PROFILE", "CMUX_DEV_AUTH_ACCOUNT", "CMUX_DEV_AUTH_REPLACE_SESSION",
        "CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD", "CMUX_UITEST_STACK_EMAIL", "CMUX_UITEST_STACK_PASSWORD",
    ]

    /// The auth launch keys of `environment`.
    nonisolated static func launchAuthKeys(from environment: [String: String]) -> [String: String] {
        environment.filter { authLaunchKeyNames.contains($0.key) }
    }

    /// The environment CloudAuth reads: the process's, plus the captured auth
    /// launch keys it no longer has (a value it still has wins).
    nonisolated static func authEnvironment(process: [String: String], launch: [String: String]) -> [String: String] {
        process.merging(launch) { current, _ in current }
    }

    /// This process's auth launch keys, read at first use: main touches it
    /// (``captureLaunchEnvironment()``) before it strips inherited variables.
    nonisolated static let launchEnvironment = launchAuthKeys(from: ProcessInfo.processInfo.environment)

    /// Captures the auth launch keys; call in main before LaunchIdentity.stripInheritedEnvironment().
    public nonisolated static func captureLaunchEnvironment() { _ = launchEnvironment }

    /// `environment` nil reads this process's environment plus the captured auth launch keys.
    public init(configuration: CloudConfiguration, environment explicitEnvironment: [String: String]? = nil,
                defaults: UserDefaults = .standard) {
        let environment = explicitEnvironment
            ?? Self.authEnvironment(process: ProcessInfo.processInfo.environment, launch: Self.launchEnvironment)
        self.configuration = configuration
        let tokenStore = FallbackTokenStore(
            primary: KeychainStackTokenStore(service: configuration.keychainService),
            fallback: FileStackTokenStore(directory: configuration.credentialsDirectory)
        )
        let config = AuthConfig(
            stack: CMUXAuthConfig(projectId: configuration.stackProjectID, publishableClientKey: configuration.stackPublishableClientKey),
            magicLinkCallbackURL: configuration.authWebOrigin.appendingPathComponent("auth/callback").absoluteString,
            apiBaseURL: configuration.apiBaseURL.absoluteString
        )
        let client = StackAuthClient(config: config, tokenStore: .custom(tokenStore),
                                     baseURL: configuration.stackBaseURL.absoluteString, noAutomaticPrefetch: true)
        let devAuth = configuration.isDebugBuild && !configuration.isProductionAuth
        var launchEnvironment = environment
        var replaceSession = false
        if devAuth, let credentials = DogfoodCredentials.resolve(environment: environment, home: NSHomeDirectory()) {
            launchEnvironment["CMUX_UITEST_STACK_EMAIL"] = credentials.email
            launchEnvironment["CMUX_UITEST_STACK_PASSWORD"] = credentials.password
            replaceSession = environment["CMUX_DEV_AUTH_REPLACE_SESSION"] == "1"
                || environment["CMUX_DEV_AUTH_PROFILE"] != nil || environment["CMUX_AUTH_CREDENTIALS_FILE"] != nil
        }
        let anchor = AuthPresentationContextProvider()
        coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "cmux.auth.hasTokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "cmux.auth.cachedUser"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "cmux.auth.selectedTeamID"),
            anchor: anchor,
            config: config,
            launch: AuthLaunchOptions(clearAuthRequested: false, mockDataEnabled: false, environment: launchEnvironment,
                                      includesDevAuth: devAuth, replaceStoredSessionWithAutoLogin: replaceSession)
        )
        callbackRouter = AuthCallbackRouter(extraAllowedScheme: configuration.callbackScheme)
        let coordinator = coordinator
        browserSignIn = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: ASWebBrowserAuthSessionFactory(anchor: anchor),
            callbackRouter: callbackRouter,
            makeSignInURL: { configuration.signInURL(callbackState: $0) },
            callbackScheme: { configuration.callbackScheme },
            openExternalURL: { NSWorkspace.shared.open($0) }
        )
    }

    /// Starts restoring the stored session (and dev auto sign-in).
    public func start() { coordinator.start() }

    public func awaitRestored() async { await coordinator.awaitBootstrapped() }

    /// A coherent access/refresh pair for one API call.
    public func tokens() async throws -> (access: String, refresh: String) {
        let pair = try await coordinator.currentTokens()
        return (pair.accessToken, pair.refreshToken)
    }

    /// Hosted browser sign-in; returns whether the app ended signed in.
    @discardableResult
    public func signIn() async -> Bool {
        await browserSignIn.beginSignIn().value
    }

    public func signOut() async { await browserSignIn.signOut() }

    /// Selects `id`; refused (false) when the device is restricted to another team.
    @discardableResult
    public func selectTeam(_ id: String) -> Bool {
        guard managedTeamID == nil || id == managedTeamID else { return false }
        coordinator.selectedTeamID = id
        return true
    }

    /// Whether `url` is a sign-in callback this build accepts, in any form
    /// (`<scheme>://auth-callback`, `<scheme>:auth-callback`), so URL
    /// routing leaves it to ``handleCallback(_:)``.
    public nonisolated func isCallback(_ url: URL) -> Bool {
        callbackRouter.isAuthCallbackURL(url)
    }

    /// Routes a `<scheme>://auth-callback` URL (browser fallback) to the flow.
    public func handleCallback(_ url: URL) async -> Bool {
        guard callbackRouter.isAuthCallbackURL(url) else { return false }
        return await browserSignIn.handleCallbackURL(url)
    }
}
