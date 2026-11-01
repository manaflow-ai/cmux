public import AppKit
public import CMUXAuthCore
public import CmuxAuthRuntime
import Foundation
import os
public import Observation
import CmuxNextCompat

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
    @ObservationIgnored private let usesCaptureFixture: Bool

    public var isSignedIn: Bool { coordinator.isAuthenticated }
    public var isRestoring: Bool { coordinator.isRestoringSession }
    public var user: CMUXAuthUser? { coordinator.currentUser }
    /// The team cmux works in; every team-scoped feature reads it (``ActiveTeam``).
    @ObservationIgnored public let activeTeam: ActiveTeam
    /// The device's managed team (``ActiveTeam/managedTeamID``).
    public var managedTeamID: String? {
        get { activeTeam.managedTeamID }
        set { activeTeam.managedTeamID = newValue }
    }
    /// The account's teams this device may use (``ActiveTeam/teams``).
    public var teams: [CMUXAuthTeam] { activeTeam.teams }
    /// The team API calls use (``ActiveTeam/id``).
    public var teamID: String? { activeTeam.id }

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
                defaults: UserDefaults = .standard, captureFixture: Bool = false) {
        #if DEBUG
        let useCaptureFixture = captureFixture && configuration.isDebugBuild
        #else
        let useCaptureFixture = false
        #endif
        usesCaptureFixture = useCaptureFixture
        let environment = useCaptureFixture ? [:] : (explicitEnvironment
            ?? Self.authEnvironment(process: ProcessInfo.processInfo.environment, launch: Self.launchEnvironment))
        self.configuration = configuration
        let tokenStore: any StackAuthTokenStoreProtocol
        let client: any AuthClient
        let authDefaults: any CMUXAuthKeyValueStore
        #if DEBUG
        if useCaptureFixture {
            let fixtureStore = CaptureFixtureTokenStore()
            tokenStore = fixtureStore
            client = CaptureFixtureAuthClient(store: fixtureStore)
            // A capture must not inherit or persist this machine's auth state.
            authDefaults = CaptureFixtureKeyValueStore()
        } else {
            let productionStore = FallbackTokenStore(
                primary: KeychainStackTokenStore(service: configuration.keychainService),
                fallback: FileStackTokenStore(directory: configuration.credentialsDirectory)
            )
            tokenStore = productionStore
            authDefaults = defaults
            client = Self.stackClient(configuration: configuration, tokenStore: productionStore)
        }
        #else
        let productionStore = FallbackTokenStore(
            primary: KeychainStackTokenStore(service: configuration.keychainService),
            fallback: FileStackTokenStore(directory: configuration.credentialsDirectory)
        )
        tokenStore = productionStore
        authDefaults = defaults
        client = Self.stackClient(configuration: configuration, tokenStore: productionStore)
        #endif
        let config = AuthConfig(
            stack: CMUXAuthConfig(projectId: configuration.stackProjectID, publishableClientKey: configuration.stackPublishableClientKey),
            magicLinkCallbackURL: configuration.authWebOrigin.appendingPathComponent("auth/callback").absoluteString,
            apiBaseURL: configuration.apiBaseURL.absoluteString
        )
        // The production client is composed above so the DEBUG capture branch
        // never constructs StackAuth's network client or touches Keychain.
        // A debug build signs in from its dogfood credentials against the development project.
        // Pointed at production (`CMUX_AUTH_ENVIRONMENT=production`), it does so only from an
        // explicit `CMUX_AUTH_CREDENTIALS_FILE`, never from the ambient secrets files: that is how
        // a hidden rig build signs a production test account in for end-to-end checks
        // (cmux-next-ios/verify). A release build never reads either.
        // The variable is read from the process environment, so pass it per launch with
        // `open --env`; an exported one would replace a production session signed in by browser.
        let explicitCredentialsFile = environment["CMUX_AUTH_CREDENTIALS_FILE"].map { !$0.isEmpty } ?? false
        let devAuth = !useCaptureFixture && configuration.isDebugBuild && (!configuration.isProductionAuth || explicitCredentialsFile)
        var launchEnvironment = environment
        var replaceSession = false
        let decision: (credentials: DogfoodCredentials?, refusal: DogfoodCredentials.Refusal?) =
            devAuth ? DogfoodCredentials.decide(environment: environment, home: NSHomeDirectory()) : (nil, nil)
        if let refusal = decision.refusal { Self.logRefusal(refusal) }
        if let credentials = decision.credentials {
            launchEnvironment["CMUX_UITEST_STACK_EMAIL"] = credentials.email
            launchEnvironment["CMUX_UITEST_STACK_PASSWORD"] = credentials.password
            replaceSession = environment["CMUX_DEV_AUTH_REPLACE_SESSION"] == "1"
                || environment["CMUX_DEV_AUTH_PROFILE"] != nil || environment["CMUX_AUTH_CREDENTIALS_FILE"] != nil
        }
        let anchor = AuthPresentationContextProvider()
        coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: authDefaults, key: "cmux.auth.hasTokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: authDefaults, key: "cmux.auth.cachedUser"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: authDefaults, key: "cmux.auth.selectedTeamID"),
            anchor: anchor,
            config: config,
            launch: AuthLaunchOptions(clearAuthRequested: false, mockDataEnabled: false, environment: launchEnvironment,
                                      includesDevAuth: devAuth, replaceStoredSessionWithAutoLogin: replaceSession),
            isOnline: { !useCaptureFixture }
        )
        activeTeam = ActiveTeam(source: coordinator)
        callbackRouter = AuthCallbackRouter(extraAllowedScheme: configuration.callbackScheme)
        let coordinator = coordinator
        #if DEBUG
        let sessionFactory: any HostBrowserAuthSessionFactory = useCaptureFixture
            ? CaptureFixtureBrowserAuthSessionFactory()
            : ASWebBrowserAuthSessionFactory(anchor: anchor)
        // Every open here follows the person's Sign In, so the browser comes to the front:
        // opened behind cmux, the click looked dead (2026-10-31). The open never blocks (cx-050n).
        let openExternalURL: @MainActor @Sendable (URL) -> Bool = { url in
            guard !useCaptureFixture else { return false }
            return NSWorkspace.shared.openInForeground(url)
        }
        #else
        let sessionFactory: any HostBrowserAuthSessionFactory = ASWebBrowserAuthSessionFactory(anchor: anchor)
        let openExternalURL: @MainActor @Sendable (URL) -> Bool = { url in
            NSWorkspace.shared.openInForeground(url)
        }
        #endif
        browserSignIn = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: sessionFactory,
            callbackRouter: callbackRouter,
            makeSignInURL: { configuration.signInURL(callbackState: $0) },
            callbackScheme: { configuration.callbackScheme },
            openExternalURL: openExternalURL
        )
    }

    private static func stackClient(configuration: CloudConfiguration,
                                    tokenStore: some StackAuthTokenStoreProtocol) -> any AuthClient {
        let config = AuthConfig(
            stack: CMUXAuthConfig(projectId: configuration.stackProjectID, publishableClientKey: configuration.stackPublishableClientKey),
            magicLinkCallbackURL: configuration.authWebOrigin.appendingPathComponent("auth/callback").absoluteString,
            apiBaseURL: configuration.apiBaseURL.absoluteString
        )
        return StackAuthClient(config: config, tokenStore: .custom(tokenStore),
                               baseURL: configuration.stackBaseURL.absoluteString, noAutomaticPrefetch: true)
    }

    /// Starts restoring the stored session (and dev auto sign-in).
    public func start() { coordinator.start() }

    public func awaitRestored() async { await coordinator.awaitBootstrapped() }

    /// A coherent access/refresh pair for one API call.
    public func tokens() async throws -> (access: String, refresh: String) {
        let pair = try await coordinator.currentTokens()
        return (pair.accessToken, pair.refreshToken)
    }

    /// Where a sign-in opens; the App reads its Debug Settings tunable here.
    @ObservationIgnored public var signInWindow: @MainActor () -> CloudSignInWindow = { .automatic }

    /// Hosted browser sign-in; returns whether the app ended signed in.
    /// Every entry point (Settings, the palette, the sidebar, the Cloud page)
    /// comes through here, so they all open the same window.
    @discardableResult
    public func signIn(selectAccount: Bool = false) async -> Bool {
        await beginSignIn(selectAccount: selectAccount).value
    }

    /// Starts a sign-in without waiting for it. `selectAccount` (Switch
    /// Account) asks the hosted page which account to use.
    @discardableResult
    public func beginSignIn(selectAccount: Bool = false) -> Task<Bool, Never> {
        let inBrowser = signInWindow().opensDefaultBrowser(defaultBrowser: CloudSignInWindow.currentDefaultBrowser())
        return browserSignIn.beginSignIn(selectAccount: selectAccount, inDefaultBrowser: inBrowser)
    }

    /// Opens the sign-in in progress in the default browser (the person's
    /// way on when the popup shows nothing); false when none is in progress.
    @discardableResult
    public func continueSignInInBrowser() -> Bool {
        guard !usesCaptureFixture, let url = browserSignIn.activeAttemptSignInURL else { return false }
        return NSWorkspace.shared.openInForeground(url)
    }

    /// Ends the sign-in in progress.
    public func cancelSignIn() { browserSignIn.cancelSignIn() }

    public func signOut() async { await browserSignIn.signOut() }

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

extension CloudAuth {
    /// Why a tagged build starts signed out (no account names or emails beyond a mask).
    nonisolated static func logRefusal(_ refusal: DogfoodCredentials.Refusal) {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "auth")
        switch refusal {
        case .noDeclaredAccount:
            logger.notice("dev auto sign-in off: no declared account (~/.config/cmux/dev-account or CMUX_DEV_AUTH_ACCOUNT)")
        case .accountMismatch(let found, let declared):
            logger.notice("dev auto sign-in off: \(mask(found), privacy: .public) is not the declared \(mask(declared), privacy: .public)")
        }
    }

    nonisolated static func mask(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return "***" }
        return String(email.prefix(1)) + "***" + String(email[at...])
    }
}
