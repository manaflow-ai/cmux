public import AppKit
public import CMUXAuthCore
public import CmuxAuthRuntime
import Foundation
import os
public import Observation
import CmuxNextCompat

private enum CaptureAuthCleanupError: Error {
    case active
}

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
    @ObservationIgnored private var captureTokenStore: CaptureFencedTokenStore?
    /// Prevents a new auth writer while a protected capture proves stores
    /// absent. Existing token readers are joined before deletion.
    @ObservationIgnored private var captureCleanupActive = false
    @ObservationIgnored private var activeTokenReads = 0
    /// The GitHub installs this sign-in finished this launch (``CloudGitHubCompletion/handle(_:auth:)``, #46018).
    @ObservationIgnored public let gitHubChanges = CloudGitHubChanges()
    /// The bundled cmux that runs this sign-in's person calls on the daemon (``CloudOwnerAPIClient``'s `cloud.owner.*`):
    /// the Cloud service sets it once at start. Nil (a test, a build without cmux): those calls answer "cmux is not available".
    @ObservationIgnored public var machineIO: CloudMachineIO?

    /// Sets ``machineIO`` to `io` and answers it.
    public func runningPersonCalls(on io: CloudMachineIO?) -> CloudMachineIO? {
        machineIO = io
        return io
    }

    @ObservationIgnored private var captureCleanupWaiters: [CheckedContinuation<Void, Never>] = []

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
    /// The account and team a sandboxed Run is sent under now (``CloudDaemon/runningAs(_:)``), nil signed out.
    public var runAccount: CloudDaemon.RunAccount? { isSignedIn ? user.map { .init(user: $0.id, team: teamID) } : nil }

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

    /// Asks a running cmux NIGHTLY for a NEW session of this build's own (`auth.session.request`: the person
    /// says yes in NIGHTLY), waiting at most the given time; nil when there is none.
    public typealias ConsentSession = @Sendable (Duration) async -> (accessToken: String?, refreshToken: String)?

    /// `environment` nil reads this process's environment plus the captured auth launch keys.
    /// `consentSession` is where a build that starts signed out asks NIGHTLY for one (Rust's `client_asks`).
    public init(configuration: CloudConfiguration, environment explicitEnvironment: [String: String]? = nil,
                defaults: UserDefaults = .standard, captureFixture: Bool = false,
                consentSession: ConsentSession? = nil) {
        #if DEBUG
        let useCaptureFixture = captureFixture && configuration.isDebugBuild
        #else
        let useCaptureFixture = false
        #endif
        usesCaptureFixture = useCaptureFixture
        let environment = useCaptureFixture ? [:] : (explicitEnvironment
            ?? Self.authEnvironment(process: ProcessInfo.processInfo.environment, launch: Self.launchEnvironment))
        self.configuration = configuration
        // A DEV build with no usable tag: every cloud client refuses (CMUXBuildSpaceError), never nightly's data.
        if let refusal = configuration.buildSpace.refusal {
            Self.fileLog.fault("cloud calls refused: \(refusal.localizedDescription, privacy: .public)")
        }
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
            let productionStore = Self.tokenStore(configuration: configuration, consentSession: consentSession,
                                                  autoLogin: signIn.autoLogin, memoryOnly: signIn.memoryOnly)
            let fencedStore = CaptureFencedTokenStore(base: productionStore)
            captureTokenStore = fencedStore
            tokenStore = fencedStore
            authDefaults = signIn.memoryOnly ? MemoryAuthKeyValueStore() : defaults
            client = Self.stackClient(configuration: configuration, tokenStore: fencedStore)
        }
        #else
        let productionStore = Self.tokenStore(configuration: configuration, consentSession: consentSession,
                                              autoLogin: signIn.autoLogin, memoryOnly: signIn.memoryOnly)
        let fencedStore = CaptureFencedTokenStore(base: productionStore)
        captureTokenStore = fencedStore
        tokenStore = fencedStore
        // A memory-only launch keeps its cached user and team off the defaults too, so the next launch
        // never shows the file's account over the session in the Keychain.
        authDefaults = signIn.memoryOnly ? MemoryAuthKeyValueStore() : defaults
        client = Self.stackClient(configuration: configuration, tokenStore: fencedStore)
        #endif
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
    /// from the namespaced store its update used (``CloudConfiguration/namespacedLegacyStorage(homeDirectory:)``).
    /// Every build keeps its own session and none reads another build's: a dev build never takes cmux NIGHTLY's
    /// (the production cloud-api ignores `X-Cmux-Build-Space`, so it would reach NIGHTLY's data). A dev build with a
    /// dev account configured (`scripts/setup-team-dev.sh`) is signed in to that account by the launch hand-off
    /// (``launchSignIn(configuration:environment:home:)``); otherwise the person signs it in once, in the browser.
    /// `memoryOnly` (a launch that signs in from an explicit file, ``LaunchSignIn/memoryOnly``) keeps the session
    /// in memory and never opens the Keychain or the file fallback.
    /// A build that Rust says asks (``asksNightlyForConsent(configuration:autoLogin:memoryOnly:storeReadFailed:)``)
    /// and finds its own store empty at its first read asks a running NIGHTLY for a NEW session (`consentSession`,
    /// after the person says yes there) and keeps it in this own store, so later launches stay signed in and a
    /// sign-out revokes it like any session of its own. It is minted for this build, never NIGHTLY's own session.
    /// A store that could not be read is not empty: no ask.
    static func tokenStore(configuration: CloudConfiguration, consentSession: ConsentSession? = nil,
                           autoLogin: Bool = false, memoryOnly: Bool = false) -> any StackAuthTokenStoreProtocol {
        if memoryOnly { return MemoryStackTokenStore() }
        let own = ownTokenStore(configuration: configuration, consentSession: consentSession, autoLogin: autoLogin,
                                memoryOnly: memoryOnly)
        guard let shared = configuration.sharedSession.map({
            KeychainStackTokenStore(service: $0.keychainService, accessGroup: $0.accessGroup)
        }) else { return own }
        return SharedSessionTokenStore(own: own, shared: shared)
    }

    /// This build's own Keychain store with its file fallback, adopting once from the namespaced store its
    /// update used.
    static func ownTokenStore(configuration: CloudConfiguration, consentSession: ConsentSession? = nil,
                              autoLogin: Bool = false, memoryOnly: Bool = false) -> any StackAuthTokenStoreProtocol {
        let own = FallbackTokenStore(
            primary: KeychainStackTokenStore(service: configuration.keychainService),
            fallback: FileStackTokenStore(directory: configuration.credentialsDirectory)
        )
        var sources: [ImportingTokenStore.Source] = []
        var forget: (@Sendable () async -> Void)?
        var failures: (@Sendable () async -> UInt64)?
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let previous = configuration.namespacedLegacyStorage(homeDirectory: home) {
            // A session signed in while the update read the namespaced store is this app's own: adopted once,
            // and cleared with a sign-out so the next launch does not sign the person back in.
            let earlier = FallbackTokenStore(primary: KeychainStackTokenStore(service: previous.keychainService),
                                             fallback: FileStackTokenStore(directory: previous.credentialsDirectory))
            sources.append {
                ImportedTokenPair(accessToken: await earlier.getStoredAccessToken(), refreshToken: await earlier.getStoredRefreshToken())
            }
            forget = { await earlier.clearTokens() }
            failures = { await earlier.tokenReadFailureCount() }
        }
        if let consentSession,
           let timeout = asksNightlyForConsent(configuration: configuration, autoLogin: autoLogin, memoryOnly: memoryOnly,
                                               storeReadFailed: false) {
            // Asked only when the own store read cleanly empty (the import runs on an empty primary).
            sources.append {
                let failed = await own.tokenReadFailureCount() > 0
                guard asksNightlyForConsent(configuration: configuration, autoLogin: autoLogin, memoryOnly: memoryOnly,
                                            storeReadFailed: failed) != nil else { return nil }
                return await consentSession(timeout).flatMap {
                    ImportedTokenPair(accessToken: $0.accessToken, refreshToken: $0.refreshToken)
                }
            }
        }
        guard !sources.isEmpty else { return own }
        // Every source is this app's own session (the consent one is minted for this build), so a sign-out
        // revokes it on the server.
        return ImportingTokenStore(primary: own, sources: sources, sharesSessions: false, forgetSources: forget,
                                   sourceReadFailures: failures)
    }

    /// How long to wait for NIGHTLY's answer when this signed-out launch asks it for a session (Rust's
    /// `client_asks` and `CLIENT_TIMEOUT`, cmux-cloud-config `handoff`); nil when it does not ask. An FFI that does
    /// not answer never asks.
    nonisolated static func asksNightlyForConsent(configuration: CloudConfiguration, autoLogin: Bool, memoryOnly: Bool,
                                                  storeReadFailed: Bool) -> Duration? {
        struct Facts: Encodable {
            var bundleId: String?, isProductionAuth: Bool, signedIn = false, storeReadFailed: Bool, memoryOnly: Bool
            var autoLogin: Bool, captureFixture = false
        }
        struct Reply: Decodable { var asks: Bool, timeoutSeconds: Int }
        let facts = Facts(bundleId: configuration.bundleID, isProductionAuth: configuration.isProductionAuth,
                          storeReadFailed: storeReadFailed, memoryOnly: memoryOnly, autoLogin: autoLogin)
        guard let reply = CloudStartCore().call("cloud_handoff_client_asks", facts, as: Reply.self), reply.asks else { return nil }
        return .seconds(reply.timeoutSeconds)
    }

    private static func stackClient(configuration: CloudConfiguration,
                                    tokenStore: some StackAuthTokenStoreProtocol) -> any AuthClient {
        let config = AuthConfig(
            stack: CMUXAuthConfig(projectId: configuration.stackProjectID, publishableClientKey: configuration.stackPublishableClientKey),
            magicLinkCallbackURL: configuration.authWebOrigin.appendingPathComponent("auth/callback").absoluteString,
            apiBaseURL: configuration.apiBaseURL.absoluteString
        )
        // A session adopted from cmux NIGHTLY, or imported from the shared item, is the other build's own: a
        // sign-out here leaves it alive on the server.
        var keepsServerSession: (@Sendable (String) async -> Bool)?
        let base: any StackAuthTokenStoreProtocol = (tokenStore as? CaptureFencedTokenStore)?.base ?? tokenStore
        if let sharing = base as? any KeepsSharedSessions {
            keepsServerSession = { (refreshToken: String) async -> Bool in
                await sharing.isShared(refreshToken: refreshToken)
            }
        }
        return StackAuthClient(config: config, tokenStore: .custom(tokenStore),
                               baseURL: configuration.stackBaseURL.absoluteString, noAutomaticPrefetch: true,
                               keepsServerSession: keepsServerSession)
    }

    /// Starts restoring the stored session (and dev auto sign-in).
    public func start() { coordinator.start() }

    public func awaitRestored() async { await coordinator.awaitBootstrapped() }
    /// The signed-in user once the stored session has restored, for code that binds an install to it: before
    /// the restore ``user`` is the cached account, which can differ from the stored token's.
    public func restoredUserID() async -> String? {
        await awaitRestored()
        return user?.id
    }

    /// The signed-in person's access token once the stored session has restored (a cold launch asks before it
    /// has); nil signed out.
    public func restoredAccessToken() async -> String? {
        await awaitRestored()
        return isSignedIn ? (try? await tokens().access) : nil
    }

    /// A coherent access/refresh pair for one API call.
    public func tokens() async throws -> (access: String, refresh: String) {
        guard !captureCleanupActive else { throw CaptureAuthCleanupError.active }
        activeTokenReads += 1
        defer { finishCaptureTokenRead() }
        let pair = try await coordinator.currentTokens()
        return (pair.accessToken, pair.refreshToken)
    }

    /// Where a sign-in opens; the App reads its Debug Settings tunable here.
    @ObservationIgnored public var signInWindow: @MainActor () -> CloudSignInWindow = { .automatic }

    /// Opens the hosted sign-in page in a cmux browser tab; false when no window can take it (then the popup or
    /// the default browser opens instead). The App installs it; nil keeps the popup-or-browser rule.
    @ObservationIgnored public var openSignInInApp: (@MainActor (URL) -> Bool)?

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
        guard !captureCleanupActive else { return Task { false } }
        let inApp = usesCaptureFixture ? nil : openSignInInApp
        switch signInWindow().place(defaultBrowser: CloudSignInWindow.currentDefaultBrowser(), inApp: inApp != nil) {
        case .inApp:
            // The page's `<scheme>://auth-callback` comes back from the tab through the app's open-URL route
            // (BrowserExternalApps.openOwn) to handleCallback, which still checks this attempt's state.
            return browserSignIn.beginSignIn(selectAccount: selectAccount, openingWith: inApp)
        case .defaultBrowser:
            return browserSignIn.beginSignIn(selectAccount: selectAccount, inDefaultBrowser: true)
        case .popup:
            return browserSignIn.beginSignIn(selectAccount: selectAccount)
        }
    }

    /// Opens the sign-in in progress in the default browser (the person's
    /// way on when the popup shows nothing); false when none is in progress.
    @discardableResult
    public func continueSignInInBrowser() -> Bool {
        guard !captureCleanupActive, !usesCaptureFixture, let url = browserSignIn.activeAttemptSignInURL else { return false }
        return NSWorkspace.shared.openInForeground(url)
    }

    /// Ends the sign-in in progress.
    public func cancelSignIn() { browserSignIn.cancelSignIn() }

    /// ``signIn(selectAccount:)`` for a waiter that may give up: cancelling the task that awaits it
    /// ends the sign-in in progress, so the next sign-in opens a fresh one instead of reusing it.
    public func signInEndedOnCancel() async -> Bool {
        await withTaskCancellationHandler { await signIn() } onCancel: { Task { @MainActor in self.cancelSignIn() } }
    }

    public func signOut() async {
        guard !captureCleanupActive else { return }
        await browserSignIn.signOut()
    }

    /// DEBUG-only proof and cleanup for the exact auth stores of a protected
    /// capture. The probe runs off the main actor and never returns token data.
    #if DEBUG || CMUX_BENCH_HOOKS
    public func captureAuthCleanup(phase: CaptureAuthCleanupPhase, leaseID: String,
                                   requestedBundleIdentifier: String) async -> CaptureAuthCleanupResult {
        guard !captureCleanupActive else { return .failure(.authNotQuiescent) }
        captureCleanupActive = true
        defer {
            captureCleanupActive = false
            let waiters = captureCleanupWaiters
            captureCleanupWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let configuration = configuration
        if let preflight = await Task.detached(priority: .utility, operation: {
            CaptureAuthPersistence().preflight(configuration: configuration, phase: phase, leaseID: leaseID,
                                               requestedBundleIdentifier: requestedBundleIdentifier)
        }).value {
            return preflight
        }
        await waitForCaptureTokenReaders()
        await captureTokenStore?.captureAwaitIdle()
        guard !browserSignIn.isSigningIn, !coordinator.isLoading, !coordinator.isRestoringSession else {
            return .failure(.authNotQuiescent)
        }
        if phase == .cleanup { await captureTokenStore?.freezeForCapture() }
        return await Task.detached(priority: .utility) {
            CaptureAuthPersistence().run(configuration: configuration, phase: phase, leaseID: leaseID,
                                         requestedBundleIdentifier: requestedBundleIdentifier)
        }.value
    }
    #endif

    /// Whether `url` is a sign-in callback this build accepts, in any form
    /// (`<scheme>://auth-callback`, `<scheme>:auth-callback`), so URL
    /// routing leaves it to ``handleCallback(_:)``.
    public nonisolated func isCallback(_ url: URL) -> Bool {
        callbackRouter.isAuthCallbackURL(url)
    }

    /// Whether `url` is this build's own link that ends a flow a cmux tab started (GitHub's
    /// `<scheme>://integration/complete` or the sign-in callback): the tab hands it over without asking.
    public func isAppHandoff(_ url: URL) -> Bool {
        CloudGitHubCompletion(url: url, scheme: configuration.callbackScheme) != nil || isCallback(url)
    }

    /// Takes an opened sign-in callback; true when sign-in then failed and Accounts should show why.
    public func callbackFailed(_ url: URL) async -> Bool {
        guard await !handleCallback(url) else { return false }
        await awaitRestored()
        return signInFailed && !isSignedIn && !isSigningIn
    }

    /// Routes a `<scheme>://auth-callback` URL (browser fallback) to the flow.
    public func handleCallback(_ url: URL) async -> Bool {
        guard !captureCleanupActive else { return false }
        guard callbackRouter.isAuthCallbackURL(url) else { return false }
        return await browserSignIn.handleCallbackURL(url)
    }

    private func waitForCaptureTokenReaders() async {
        guard activeTokenReads > 0 else { return }
        await withCheckedContinuation { captureCleanupWaiters.append($0) }
    }

    private func finishCaptureTokenRead() {
        activeTokenReads -= 1
        guard activeTokenReads == 0 else { return }
        let waiters = captureCleanupWaiters
        captureCleanupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// A token store that can say a refresh token is another app's session, which a sign-out here must leave
/// alive on the server (`StackAuthClient`'s `keepsServerSession`).
protocol KeepsSharedSessions: Sendable {
    func isShared(refreshToken: String) async -> Bool
}

extension ImportingTokenStore: KeepsSharedSessions {}

/// The token store of a Team-signed production build that shares its session with the others (Rust's
/// `shared_session`): this build's own store, plus the one shared item in the Keychain access group every
/// such build carries. Its rules are Rust's (cmux-cloud-config `shared_session_store`, with their tests:
/// own session wins, a signed-out launch imports the item read-only in memory, only its own session is
/// written to or withdrawn from the item); this actor keeps Rust's state and does the Keychain I/O each
/// answer names. A build signed without the access group gets `errSecMissingEntitlement` from every query
/// on the item: nothing is imported and nothing written.
actor SharedSessionTokenStore: StackAuthTokenStoreProtocol, KeepsSharedSessions {
    private struct Pair: Codable { var access: String?; var refresh: String? }
    private struct State: Codable { var settled = false; var usesImported = false; var importedTokens: [String] = [] }
    private struct Event: Encodable {
        var event: String
        var skipImport: Bool?, ownRefresh: String?, pair: Pair?, op: String?, refresh: String?
        var store: String?, compare: String?, before: Pair?, now: Pair?
    }
    private struct Effect: Decodable { let kind: String; let store: String?; let access: String?; let refresh: String? }
    private struct Reply: Decodable { let state: State; let effects: [Effect]; let shared: Bool }
    private struct Request: Encodable { let state: State; let event: Event }
    private typealias Apply = (any StackAuthTokenStoreProtocol) async -> Bool

    private let own: any StackAuthTokenStoreProtocol
    private let shared: any StackAuthTokenStoreProtocol
    private let imported = MemoryStackTokenStore()
    private var state = State()
    private var settling: Task<Void, Never>?
    private let log = AuthDebugLog()

    /// - Parameters:
    ///   - own: This build's store; every session it signs in to is written here.
    ///   - shared: The shared item's store (its Keychain service and access group).
    init(own: any StackAuthTokenStoreProtocol, shared: any StackAuthTokenStoreProtocol) {
        self.own = own
        self.shared = shared
    }

    func isShared(refreshToken: String) async -> Bool { await run(Event(event: "is_shared", refresh: refreshToken)) }
    func tokenReadFailureCount() async -> UInt64 { await own.tokenReadFailureCount() }
    func captureAwaitIdle() async { await own.captureAwaitIdle() }

    func getStoredAccessToken() async -> String? {
        await settle()
        return await (state.usesImported ? imported : own).getStoredAccessToken()
    }

    func getStoredRefreshToken() async -> String? {
        await settle()
        return await (state.usesImported ? imported : own).getStoredRefreshToken()
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        await settle(skippingImport: true)
        await run(Event(event: "call", op: "set_tokens", refresh: refreshToken)) {
            await $0.setTokens(accessToken: accessToken, refreshToken: refreshToken); return false
        }
    }

    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        await settle()
        await run(Event(event: "call", op: "compare_and_set", refresh: compareRefreshToken)) {
            await $0.compareAndSet(compareRefreshToken: compareRefreshToken, newRefreshToken: newRefreshToken,
                                   newAccessToken: newAccessToken)
            return false
        }
    }

    func clearTokens() async {
        await settle(skippingImport: true)
        await run(Event(event: "call", op: "clear")) { await $0.clearTokens(); return false }
    }

    @discardableResult
    func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        await settle(skippingImport: true)
        return await run(Event(event: "call", op: "clear_if_current")) {
            await $0.clearTokensIfCurrent(accessToken: accessToken, refreshToken: refreshToken)
        }
    }

    /// The launch import, once per process (none after an earlier write); later calls wait for it.
    private func settle(skippingImport: Bool = false) async {
        if settling == nil {
            settling = Task {
                let mine = skippingImport ? nil : await own.getStoredRefreshToken()
                await run(Event(event: "settle", skipImport: skippingImport, ownRefresh: mine))
            }
        }
        await settling?.value
    }

    private func store(_ name: String?) -> any StackAuthTokenStoreProtocol { name == "imported" ? imported : own }

    private func pair(_ store: any StackAuthTokenStoreProtocol) async -> Pair {
        Pair(access: await store.getStoredAccessToken(), refresh: await store.getStoredRefreshToken())
    }

    /// Asks Rust for `event`'s next state and effects and performs them; `apply` is the call an `apply`
    /// effect makes on the store it names. Returns `apply`'s answer, or Rust's `shared`.
    @discardableResult
    private func run(_ event: Event, apply: Apply? = nil) async -> Bool {
        let request = Request(state: state, event: event)
        guard let reply = CloudStartCore().call("cloud_auth_shared_session_next", request, as: Reply.self) else {
            // No answer: this build's own store only, nothing shared.
            log.log("shared.store: no answer for \(event.event)")
            return await apply?(own) ?? false
        }
        state = reply.state
        var answer = reply.shared
        for effect in reply.effects {
            switch effect.kind {
            case "read_shared":
                await run(Event(event: "shared_read", pair: await pair(shared)))
            case "seed_imported":
                await imported.setTokens(accessToken: effect.access, refreshToken: effect.refresh)
                log.log("shared.store: imported the shared session hasAccess=\(effect.access != nil)")
            case "apply":
                guard let apply else { continue }
                let target = store(effect.store)
                let before = await pair(target)
                answer = await apply(target)
                await run(Event(event: "applied", store: effect.store, compare: event.refresh, before: before,
                                now: await pair(target)))
            case "clear":
                await store(effect.store).clearTokens()
            case "write_shared":
                await shared.setTokens(accessToken: effect.access, refreshToken: effect.refresh)
            case "withdraw_shared":
                guard let refresh = effect.refresh else { continue }
                await shared.clearTokensIfCurrent(accessToken: nil, refreshToken: refresh)
            default:
                log.log("shared.store: unknown effect \(effect.kind)")
            }
        }
        return answer
    }
}
