public import AppKit
public import CMUXAuthCore
public import CmuxAuthRuntime
import Foundation
import os
public import Observation
import CmuxNextCompat

/// Stack Auth for cmux-next, composed from the kept `CmuxAuthRuntime`
/// library exactly as the old app did (MacAuthComposition): the Keychain
/// token store with the file fallback and `cmux.auth.*` defaults keys (scoped
/// to the staging project for signed NEXT DEV), `AuthCoordinator` for restore and
/// tokens, and `HostBrowserSignInFlow` for the hosted browser sign-in.
/// Tokens are never cached here; every API call asks the coordinator.
@MainActor @Observable
public final class CloudAuth {
    public let configuration: CloudConfiguration
    @ObservationIgnored public let coordinator: AuthCoordinator
    @ObservationIgnored public let browserSignIn: HostBrowserSignInFlow
    @ObservationIgnored private let callbackRouter: AuthCallbackRouter
    @ObservationIgnored private let usesCaptureFixture: Bool
    /// This build's stored session (refresh token, and the access token when one is stored), read off the
    /// main actor: what cmux NIGHTLY hands to another local cmux build (`auth.session.handoff`). Nil when
    /// signed out. The two tokens are one pair (``consistentSession(refresh:access:)``).
    @ObservationIgnored public nonisolated let storedSession: @Sendable () async -> (accessToken: String?, refreshToken: String)?

    public var isSignedIn: Bool { coordinator.isAuthenticated }
    public var isRestoring: Bool { coordinator.isRestoringSession }
    public var user: CMUXAuthUser? { coordinator.currentUser }
    /// The signed-in account's platform user id (`user_…`, the API's `userIdFor`): the id a cmux-next
    /// machine record names its `creator` by, never the Stack id in ``user``.
    public var platformUserID: String? {
        user.map { CloudAccessToken.backendUserID(stackProjectID: configuration.stackProjectID, stackUserID: $0.id) }
    }
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
    /// Who is signed in and in which team, nil signed out: a change means the account's data (its
    /// machines, its team's lists) belongs to someone else now. Observable (both halves are).
    public var accountKey: String? { isSignedIn ? "\(user?.id ?? "")|\(teamID ?? "")" : nil }

    /// How a launch signs in from the credentials it was given (Rust's `LaunchSignIn`, cmux-cloud-config `auth`).
    struct LaunchSignIn: Equatable, Codable {
        /// The debug sign-in surface: the ambient dogfood files and the `42` shortcut.
        var devAuth: Bool
        /// Whether the launch resolves credentials and signs in from them.
        var autoLogin: Bool
        /// Whether resolved credentials replace a session already stored.
        var replacesSession: Bool
        /// Whether the session lives in memory only: never read from or written to the Keychain, the
        /// credentials file or the defaults, so it ends with the process.
        var memoryOnly = false

        static let noSignIn = LaunchSignIn(devAuth: false, autoLogin: false, replacesSession: false)
    }

    /// The facts Rust's launch rules read.
    private struct Build: Encodable {
        var bundleId: String?, isDebugBuild: Bool, isProductionAuth: Bool
        init(_ configuration: CloudConfiguration) {
            bundleId = configuration.bundleID
            isDebugBuild = configuration.isDebugBuild
            isProductionAuth = configuration.isProductionAuth
        }
    }

    /// ``LaunchSignIn`` for `configuration` launched with `environment` (Rust's `launch_sign_in`), and the files its
    /// account pick reads. An FFI that does not answer never signs in from the launch.
    nonisolated static func launchSignIn(configuration: CloudConfiguration, environment: [String: String],
                                         home: String = NSHomeDirectory()) -> (signIn: LaunchSignIn, paths: [String]) {
        struct Request: Encodable { var build: Build, environment: [String: String], home: String }
        struct Reply: Decodable { var signIn: LaunchSignIn, paths: [String] }
        let request = Request(build: Build(configuration), environment: environment, home: home)
        guard let reply = CloudStartCore().call("cloud_auth_launch_sign_in", request, as: Reply.self) else { return (.noSignIn, []) }
        return (reply.signIn, reply.paths)
    }

    /// What the launch's sign-in does (Rust's `LaunchLogin`).
    struct LaunchLogin: Decodable {
        struct Credentials: Decodable { var email: String, password: String }
        var credentials: Credentials?
        var replaceSession: Bool
        var allowsEnvironmentAutoLogin: Bool
        var refusalLog: String?
    }

    /// The account the launch signs in from `paths` (``launchSignIn(configuration:environment:home:)``), read here: the
    /// explicit `CMUX_AUTH_CREDENTIALS_FILE` only when it is this user's regular 0600 file. Values never leave this
    /// process and are never logged.
    nonisolated static func launchLogin(_ signIn: LaunchSignIn, paths: [String], environment: [String: String],
                                        home: String = NSHomeDirectory()) -> LaunchLogin? {
        struct Reads: Encodable { var environment: [String: String], home: String, files: [String: String], explicitFileSecure: Bool }
        struct Request: Encodable { var signIn: LaunchSignIn, reads: Reads? }
        var reads: Reads?
        if signIn.autoLogin {
            let explicit = environment["CMUX_AUTH_CREDENTIALS_FILE"].flatMap { $0.isEmpty ? nil : $0 }
            let secure = explicit.map(ownerOnlyRegularFile) ?? false
            var files: [String: String] = [:]
            for path in paths where path != explicit || secure {
                files[path] = try? String(contentsOfFile: path, encoding: .utf8)
            }
            reads = Reads(environment: environment, home: home, files: files, explicitFileSecure: secure)
            // Each way the explicit file signs nobody in is logged (`auth`), so a launch left signed out says why; never a value.
            if explicit != nil, !secure {
                fileLog.notice("credentials file sign-in off: the file is not a regular file of this user, 0600 or stricter")
            } else if let explicit, files[explicit] == nil {
                fileLog.notice("credentials file sign-in off: the file could not be read")
            }
        }
        let login = CloudStartCore().call("cloud_auth_launch_login", Request(signIn: signIn, reads: reads), as: LaunchLogin.self)
        if let reads, let explicit = reads.environment["CMUX_AUTH_CREDENTIALS_FILE"], !explicit.isEmpty,
           reads.files[explicit] != nil, login?.credentials == nil, login?.refusalLog == nil {
            fileLog.notice("credentials file sign-in off: no CMUX_DOGFOOD_STACK_ or CMUX_UITEST_STACK_ email and password pair in it")
        }
        return login
    }

    private nonisolated static let fileLog = Logger(subsystem: "com.cmuxterm.app.next", category: "auth")

    /// Whether `path` is a regular file owned by this user, 0600 or stricter (a symlink is not).
    nonisolated static func ownerOnlyRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return false }
        return info.st_mode & 0o077 == 0
    }

    /// The auth launch keys of `environment` (Rust's `launch_keys`): main strips inherited CMUX_* variables before
    /// anything reads them (LaunchIdentity), so these are captured first and reach CloudAuth only, never a child.
    nonisolated static func launchAuthKeys(from environment: [String: String]) -> [String: String] {
        struct Reply: Decodable { var keys: [String: String] }
        return CloudStartCore().call("cloud_auth_launch_keys", ["environment": environment], as: Reply.self)?.keys ?? [:]
    }

    /// The environment CloudAuth reads: the process's, plus the captured auth
    /// launch keys it no longer has (a value it still has wins; Rust's `auth_environment`).
    nonisolated static func authEnvironment(process: [String: String], launch: [String: String]) -> [String: String] {
        struct Reply: Decodable { var environment: [String: String] }
        return CloudStartCore().call("cloud_auth_environment", ["process": process, "launch": launch], as: Reply.self)?.environment ?? process
    }

    /// This process's auth launch keys, read at first use: main touches it
    /// (``captureLaunchEnvironment()``) before it strips inherited variables.
    nonisolated static let launchEnvironment = launchAuthKeys(from: ProcessInfo.processInfo.environment)

    /// Captures the auth launch keys; call in main before LaunchIdentity.stripInheritedEnvironment().
    public nonisolated static func captureLaunchEnvironment() { _ = launchEnvironment }

    /// Asks a running cmux NIGHTLY for its session (`auth.session.handoff`); nil when there is none.
    public typealias NightlySession = @Sendable () async -> (accessToken: String?, refreshToken: String)?

    /// `environment` nil reads this process's environment plus the captured auth launch keys.
    /// `nightlySession` is where a build that ``CloudConfiguration/adoptsNightlySession`` gets its session.
    public init(configuration: CloudConfiguration, environment explicitEnvironment: [String: String]? = nil,
                defaults: UserDefaults = .standard, captureFixture: Bool = false, nightlySession: NightlySession? = nil) {
        #if DEBUG
        let useCaptureFixture = captureFixture && configuration.isDebugBuild
        #else
        let useCaptureFixture = false
        #endif
        usesCaptureFixture = useCaptureFixture
        let environment = useCaptureFixture ? [:] : (explicitEnvironment
            ?? Self.authEnvironment(process: ProcessInfo.processInfo.environment, launch: Self.launchEnvironment))
        self.configuration = configuration
        let launch = useCaptureFixture ? (signIn: LaunchSignIn.noSignIn, paths: [String]())
            : Self.launchSignIn(configuration: configuration, environment: environment)
        let signIn = launch.signIn
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
            let productionStore = Self.tokenStore(configuration: configuration, nightlySession: nightlySession,
                                                  memoryOnly: signIn.memoryOnly)
            tokenStore = productionStore
            authDefaults = signIn.memoryOnly ? MemoryAuthKeyValueStore() : defaults
            client = Self.stackClient(configuration: configuration, tokenStore: productionStore)
        }
        #else
        let productionStore = Self.tokenStore(configuration: configuration, nightlySession: nightlySession,
                                              memoryOnly: signIn.memoryOnly)
        tokenStore = productionStore
        // A memory-only launch keeps its cached user and team off the defaults too, so the next launch
        // never shows the file's account over the session in the Keychain.
        authDefaults = signIn.memoryOnly ? MemoryAuthKeyValueStore() : defaults
        client = Self.stackClient(configuration: configuration, tokenStore: productionStore)
        #endif
        let sessionStore = tokenStore
        storedSession = {
            await Self.consistentSession(refresh: { await sessionStore.getStoredRefreshToken() },
                                         access: { await sessionStore.getStoredAccessToken() })
        }
        let config = AuthConfig(
            stack: CMUXAuthConfig(projectId: configuration.stackProjectID, publishableClientKey: configuration.stackPublishableClientKey),
            magicLinkCallbackURL: configuration.authWebOrigin.appendingPathComponent("auth/callback").absoluteString,
            apiBaseURL: configuration.apiBaseURL.absoluteString
        )
        // The production client is composed above so the DEBUG capture branch
        // never constructs StackAuth's network client or touches Keychain.
        // Which launches sign in from which credentials is Rust's (``launchSignIn``); the account
        // goes to the coordinator's auto-login as the `CMUX_UITEST_STACK_*` launch keys.
        // The variables are read from the process environment, so pass them per launch with
        // `open --env`; an exported one would replace a production session signed in by browser.
        var launchEnvironment = environment
        let login = signIn.autoLogin ? Self.launchLogin(signIn, paths: launch.paths, environment: environment) : nil
        if let refusal = login?.refusalLog {
            Logger(subsystem: "com.cmuxterm.app.next", category: "auth").notice("\(refusal, privacy: .public)")
        }
        if let credentials = login?.credentials {
            launchEnvironment["CMUX_UITEST_STACK_EMAIL"] = credentials.email
            launchEnvironment["CMUX_UITEST_STACK_PASSWORD"] = credentials.password
        }
        let anchor = AuthPresentationContextProvider()
        coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: authDefaults, key: configuration.authDefaultsKey("cmux.auth.hasTokens")),
            userCache: CMUXAuthIdentityStore(keyValueStore: authDefaults, key: configuration.authDefaultsKey("cmux.auth.cachedUser")),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: authDefaults, key: configuration.authDefaultsKey("cmux.auth.selectedTeamID")),
            anchor: anchor,
            config: config,
            launch: AuthLaunchOptions(clearAuthRequested: false, mockDataEnabled: false, environment: launchEnvironment,
                                      includesDevAuth: signIn.devAuth, replaceStoredSessionWithAutoLogin: login?.replaceSession ?? false,
                                      // A signed build signs in only from the file's resolved credentials, never raw launch keys.
                                      allowsEnvironmentAutoLogin: login?.allowsEnvironmentAutoLogin ?? signIn.devAuth),
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

    /// This build's own Keychain store with its file fallback; an empty legacy default adopts, once, a session
    /// from the namespaced store its update used (``CloudConfiguration/namespacedLegacyStorage(homeDirectory:)``). Signed NEXT DEV on the NIGHTLY account
    /// (``CloudConfiguration/adoptsNightlySession``) instead keeps its session in memory only and, when it
    /// has none, adopts the one a running cmux NIGHTLY hands over (`nightlySession`). NIGHTLY's own session
    /// is only read, never changed or cleared, and a sign-out here leaves it alive on the server
    /// (``stackClient(configuration:tokenStore:)``). Without `nightlySession` (no NIGHTLY to ask) that
    /// build starts signed out.
    /// `memoryOnly` (a launch that signs in from an explicit file, ``LaunchSignIn/memoryOnly``) keeps the session
    /// in memory and never opens the Keychain or the file fallback.
    static func tokenStore(configuration: CloudConfiguration, nightlySession: NightlySession?,
                           memoryOnly: Bool = false) -> any StackAuthTokenStoreProtocol {
        if memoryOnly { return MemoryStackTokenStore() }
        guard configuration.adoptsNightlySession else {
            let own = FallbackTokenStore(
                primary: KeychainStackTokenStore(service: configuration.keychainService),
                fallback: FileStackTokenStore(directory: configuration.credentialsDirectory)
            )
            let home = FileManager.default.homeDirectoryForCurrentUser
            guard let previous = configuration.namespacedLegacyStorage(homeDirectory: home) else { return own }
            // A session signed in while the update read the namespaced store is this app's own: adopted once,
            // and cleared with a sign-out so the next launch does not sign the person back in.
            let earlier = FallbackTokenStore(primary: KeychainStackTokenStore(service: previous.keychainService),
                                             fallback: FileStackTokenStore(directory: previous.credentialsDirectory))
            return ImportingTokenStore(primary: own, sources: [{
                ImportedTokenPair(accessToken: await earlier.getStoredAccessToken(), refreshToken: await earlier.getStoredRefreshToken())
            }], sharesSessions: false, forgetSources: { await earlier.clearTokens() })
        }
        let sources: [ImportingTokenStore.Source] = nightlySession.map { fetch in
            [{ await fetch().flatMap { ImportedTokenPair(accessToken: $0.accessToken, refreshToken: $0.refreshToken) } }]
        } ?? []
        return ImportingTokenStore(primary: MemoryStackTokenStore(), sources: sources)
    }

    private static func stackClient(configuration: CloudConfiguration,
                                    tokenStore: some StackAuthTokenStoreProtocol) -> any AuthClient {
        let config = AuthConfig(
            stack: CMUXAuthConfig(projectId: configuration.stackProjectID, publishableClientKey: configuration.stackPublishableClientKey),
            magicLinkCallbackURL: configuration.authWebOrigin.appendingPathComponent("auth/callback").absoluteString,
            apiBaseURL: configuration.apiBaseURL.absoluteString
        )
        // A session adopted from cmux NIGHTLY is NIGHTLY's own: a sign-out here leaves it alive on the server.
        var keepsServerSession: (@Sendable (String) async -> Bool)?
        if let importing = tokenStore as? ImportingTokenStore {
            keepsServerSession = { (refreshToken: String) async -> Bool in
                await importing.isShared(refreshToken: refreshToken)
            }
        }
        return StackAuthClient(config: config, tokenStore: .custom(tokenStore),
                               baseURL: configuration.stackBaseURL.absoluteString, noAutomaticPrefetch: true,
                               keepsServerSession: keepsServerSession)
    }

    /// Starts restoring the stored session (and dev auto sign-in).
    public func start() { coordinator.start() }

    public func awaitRestored() async { await coordinator.awaitBootstrapped() }

    /// The signed-in person's access token once the stored session has restored (a cold launch asks before it
    /// has); nil signed out.
    public func restoredAccessToken() async -> String? {
        await awaitRestored()
        return isSignedIn ? (try? await tokens().access) : nil
    }

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

    /// ``signIn(selectAccount:)`` for a waiter that may give up: cancelling the task that awaits it
    /// ends the sign-in in progress, so the next sign-in opens a fresh one instead of reusing it.
    public func signInEndedOnCancel() async -> Bool {
        await withTaskCancellationHandler { await signIn() } onCancel: { Task { @MainActor in self.cancelSignIn() } }
    }

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
    /// The stored pair, read so a refresh that rotates the tokens between the two reads is never handed out
    /// half old: the refresh token is read before and after the access token, and the read is retried (three
    /// times at most) until both agree. Nil when signed out or when the tokens keep rotating.
    nonisolated static func consistentSession(refresh: () async -> String?, access: () async -> String?) async
        -> (accessToken: String?, refreshToken: String)? {
        for _ in 0 ..< 3 {
            guard let before = await refresh(), !before.isEmpty else { return nil }
            let accessToken = await access()
            if await refresh() == before { return (accessToken, before) }
        }
        return nil
    }
}
