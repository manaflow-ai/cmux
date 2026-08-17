import CMUXAuthCore
import CmuxAuthRuntime
import AppKit
import Foundation
import StackAuth

/// The macOS auth composition root.
///
/// Constructs the de-singletonized auth graph once at app startup, mirroring
/// the iOS `MobileAuthComposition`: the keychain/file fallback token store, a
/// `StackClientApp` over it (wrapped in ``CmuxAuthRuntime/StackAuthClient``),
/// the shared ``CmuxAuthRuntime/AuthCoordinator`` bound to the historical mac
/// defaults keys, and the ``HostBrowserSignInFlow``. Replaces
/// `AuthManager.shared`.
@MainActor
struct MacAuthComposition {
    /// The shared auth orchestrator (session state, tokens, teams).
    let coordinator: AuthCoordinator
    /// Recognizes/parses auth callback URLs (AppDelegate URL routing).
    let callbackRouter: AuthCallbackRouter
    /// The token store the Stack client persists through.
    let tokenStore: any StackAuthTokenStoreProtocol
    /// The hosted-browser sign-in flow used by app-session recovery.
    let browserSignIn: HostBrowserSignInFlow
    /// Bridges the native Stack session into explicitly opened cmux web panes.
    let browserAppSession: BrowserAppSessionController
    /// Shared observable account projection used by Settings and sidebar UI.
    let accountFlow: HostAccountFlow

    /// Build the auth graph.
    /// - Parameters:
    ///   - environment: The process environment (UI-test launch options).
    ///   - defaults: Persistence for the cached user / has-tokens flag /
    ///     selected team (historical `cmux.auth.*` keys).
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let resolvedAuthEnvironment = AuthEnvironment.resolvedStackAuthEnvironment(
            environment: environment,
            isDebugBuild: Self.isDebugBuild
        )
        let stackProjectID = AuthEnvironment.resolvedStackProjectID(
            environment: environment,
            isDebugBuild: Self.isDebugBuild
        )
        let stackPublishableClientKey = AuthEnvironment.resolvedStackPublishableClientKey(
            environment: environment,
            isDebugBuild: Self.isDebugBuild
        )
        let tokenStore = FallbackTokenStore(
            primary: KeychainStackTokenStore(
                service: KeychainStackTokenStore.serviceName(bundleIdentifier: bundleIdentifier)
            ),
            fallback: FileStackTokenStore(directory: Self.credentialsDirectory(bundleIdentifier: bundleIdentifier))
        )
        self.tokenStore = tokenStore

        let userCache = CMUXAuthIdentityStore(
            keyValueStore: defaults,
            key: "cmux.auth.cachedUser"
        )
        let sessionCache = CMUXAuthSessionCache(
            keyValueStore: defaults,
            key: "cmux.auth.hasTokens"
        )
        // One-time migration: the deleted AuthManager never wrote a has-tokens
        // flag. Prime it from the cached user so the first post-migration
        // launch primes as "restoring" instead of flashing signed-out while
        // the stored session validates.
        if defaults.object(forKey: "cmux.auth.hasTokens") == nil,
           (try? userCache.load()) != nil {
            sessionCache.setHasTokens(true)
        }

        let config = AuthConfig(
            stack: CMUXAuthConfig(
                projectId: stackProjectID,
                publishableClientKey: stackPublishableClientKey
            ),
            magicLinkCallbackURL: AuthEnvironment.websiteOrigin
                .appendingPathComponent("auth/callback", isDirectory: false)
                .absoluteString,
            apiBaseURL: AuthEnvironment.apiBaseURL.absoluteString
        )
        let client = StackAuthClient(
            config: config,
            tokenStore: .custom(tokenStore),
            baseURL: AuthEnvironment.stackBaseURL.absoluteString,
            noAutomaticPrefetch: true
        )
        // DEBUG-only: make a tagged `cmux DEV` build come up already signed in
        // as the dogfood account, mirroring iOS. A tagged build is a separate
        // bundle (separate keychain), so it starts signed out. iOS injects
        // `CMUX_UITEST_STACK_*` into the launch environment; the Mac app needs
        // the same, but a `cmux DEV` opened from Finder / the CMUX Tag Opener
        // does not inherit a shell's environment, so the resolver also reads
        // `~/.secrets/cmuxterm-dev.env` / `~/.secrets/cmux.env` directly. The
        // resolver runs unconditionally and applies file-first precedence, so
        // on the dog Mac the verified dogfood file wins even when stale Stack
        // creds are present in the environment; only the two resolved cred keys
        // are filled in (never the whole file). When the only creds are
        // `CMUX_UITEST_STACK_*` env (a CI UI test with no `~/.secrets` files),
        // the resolver returns that same pair, so the merge is a no-op. The
        // existing `CMUXAuthAutoLoginCredentials` + `shouldStartAutoLogin` gate
        // then fires unchanged. Compiled out of release builds.
        let resolvedEnvironment = Self.environmentWithDogfoodAutoSignIn(environment)
        let authProjectSwitched = Self.detectAuthProjectSwitch(
            resolvedProjectID: stackProjectID,
            buildDefaultProjectID: AuthEnvironment.resolvedStackProjectID(
                environment: [:],
                isDebugBuild: Self.isDebugBuild
            ),
            defaults: defaults
        )
        let includesDevAuth = Self.includesDevAuth(
            resolvedAuthEnvironment: resolvedAuthEnvironment
        )
        let replacesStoredDevSession = includesDevAuth
            && resolvedEnvironment["CMUX_DEV_AUTH_CREDENTIALS_RESOLVED"] == "1"
        let launch = AuthLaunchOptions(
            clearAuthRequested: resolvedEnvironment["CMUX_UITEST_CLEAR_AUTH"] == "1",
            mockDataEnabled: false,
            environment: resolvedEnvironment,
            includesDevAuth: includesDevAuth,
            clearStaleAuthOnLaunch: authProjectSwitched,
            replaceStoredSessionWithAutoLogin: replacesStoredDevSession
        )

        let anchor = AuthPresentationContextProvider()
        let browserAppSessionSignInRelay = BrowserAppSessionSignInRelay()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: sessionCache,
            userCache: userCache,
            teamSelection: CMUXAuthTeamSelectionStore(
                keyValueStore: defaults,
                key: "cmux.auth.selectedTeamID"
            ),
            anchor: anchor,
            config: config,
            launch: launch,
            onSessionWillTransition: {
                browserAppSessionSignInRelay.sessionWillTransition()
            },
            onSignedIn: {
                await browserAppSessionSignInRelay.signedIn()
            }
        )
        self.coordinator = coordinator
        let browserAppSession = BrowserAppSessionController(
            coordinator: coordinator,
            webOrigin: AuthEnvironment.appSessionHandoffOrigin,
            projectID: stackProjectID,
            defaults: defaults
        )
        self.browserAppSession = browserAppSession
        browserAppSessionSignInRelay.bind(
            beginTransition: { [weak browserAppSession] in
                browserAppSession?.beginAuthTransition()
            },
            resume: { [weak browserAppSession] in
                await browserAppSession?.resumeAfterSignIn()
            }
        )
        let callbackRouter = AuthCallbackRouter(
            extraAllowedScheme: AuthEnvironment.callbackScheme
        )
        self.callbackRouter = callbackRouter
        let browserSignIn = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: ASWebBrowserAuthSessionFactory(anchor: anchor),
            callbackRouter: callbackRouter,
            makeSignInURL: { AuthEnvironment.signInURL(callbackState: $0) },
            callbackScheme: { AuthEnvironment.callbackScheme },
            openExternalURL: { NSWorkspace.shared.open($0) },
            beginSignOut: {
                browserAppSession.beginAuthTransition()
                MobileHostIrohRuntime.shared.beginSignOutPreparation()
            },
            localSignOut: {
                await browserAppSession.clearCmuxWebSession()
            },
            onSignedOut: { accessToken, refreshToken in
                await MobileHostIrohRuntime.shared.revokeAfterSignOut(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }
        )
        self.browserSignIn = browserSignIn
        self.accountFlow = HostAccountFlow(
            coordinator: coordinator,
            browserSignIn: browserSignIn
        )
    }

    /// Begin asynchronous session restore. Call once after construction, at
    /// the composition root.
    func start() {
        coordinator.start()
    }

    /// Where the file-fallback token store persists, namespaced by bundle id
    /// (matching the pre-package layout so existing sessions survive).
    private static func credentialsDirectory(bundleIdentifier: String?) -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(bundleIdentifier ?? "cmux", isDirectory: true)
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func includesDevAuth(
        resolvedAuthEnvironment: CMUXAuthEnvironment
    ) -> Bool {
        isDebugBuild && resolvedAuthEnvironment == .development
    }

    nonisolated static let storedStackProjectIDKey = "cmux.auth.stackProjectID"

    /// Keep cached identities and Stack tokens from crossing projects when one
    /// tagged Debug bundle is rebuilt with `--prod-auth`, or switched back.
    nonisolated static func detectAuthProjectSwitch(
        resolvedProjectID: String,
        buildDefaultProjectID: String,
        defaults: UserDefaults
    ) -> Bool {
        let previous = defaults.string(forKey: storedStackProjectIDKey) ?? buildDefaultProjectID
        defaults.set(resolvedProjectID, forKey: storedStackProjectIDKey)
        return previous != resolvedProjectID
    }

    #if DEBUG
    /// Returns `environment` with the dogfood auto-sign-in credentials filled in
    /// under the `CMUX_UITEST_STACK_*` keys (DEBUG only; the whole method is
    /// compiled out of release, so the auto-sign-in path can never run in
    /// production).
    ///
    /// Always consults ``DebugDogfoodCredentialResolver`` so the resolver's
    /// file-first precedence is honored even when stale `CMUX_UITEST_STACK_*`
    /// or `CMUX_DOGFOOD_STACK_*` vars are already present in the environment:
    /// on the dog Mac, the verified `~/.secrets/cmuxterm-dev.env` account must
    /// win, while a CI UI test with no `~/.secrets` files still resolves the
    /// env pair and merges it unchanged.
    ///
    /// - Parameters:
    ///   - environment: The launch environment.
    ///   - secretFilePaths: Ordered secret-file candidates for the resolver.
    ///     Defaults to `nil` so the resolver uses `~/.secrets/cmuxterm-dev.env`
    ///     then `~/.secrets/cmux.env`. Injected by tests to exercise the
    ///     dog-Mac precedence without touching real files.
    ///   - readFile: File reader seam for the resolver. Defaults to a real read;
    ///     injected by tests.
    ///
    /// `nonisolated`: a pure transformation over its arguments that touches no
    /// main-actor state, so tests can call it from a nonisolated context.
    nonisolated static func environmentWithDogfoodAutoSignIn(
        _ environment: [String: String],
        secretFilePaths: [String]? = nil,
        readFile: ((String) -> String?)? = nil
    ) -> [String: String] {
        let resolver: DebugDogfoodCredentialResolver
        if let readFile {
            resolver = DebugDogfoodCredentialResolver(
                environment: environment,
                secretFilePaths: secretFilePaths,
                readFile: readFile
            )
        } else {
            resolver = DebugDogfoodCredentialResolver(
                environment: environment,
                secretFilePaths: secretFilePaths
            )
        }
        guard let resolved = resolver.resolve() else {
            var unresolved = environment
            unresolved["CMUX_DEV_AUTH_CREDENTIALS_RESOLVED"] = nil
            unresolved["CMUX_DEV_AUTH_REPLACE_SESSION"] = nil
            return unresolved
        }
        let replacementRequested = environment[DebugDogfoodCredentialResolver.authProfileEnvironmentKey] != nil
            || environment[DebugDogfoodCredentialResolver.explicitCredentialsFileEnvironmentKey] != nil
            || environment["CMUX_DEV_AUTH_REPLACE_SESSION"] == "1"
        var merged = environment
        merged["CMUX_UITEST_STACK_EMAIL"] = resolved.email
        merged["CMUX_UITEST_STACK_PASSWORD"] = resolved.password
        if replacementRequested {
            // Credential resolution is the deterministic identity selection
            // for an explicit tagged DEBUG launch, even when the source is a
            // file and the secret values never arrive in the process
            // environment. Mirror the iOS launch contract so a stale stored
            // session cannot survive under a different account.
            merged["CMUX_DEV_AUTH_CREDENTIALS_RESOLVED"] = "1"
            merged["CMUX_DEV_AUTH_REPLACE_SESSION"] = "1"
        } else {
            // Preserve legacy launches that only discover ambient credentials:
            // they may auto-login when signed out, but must not clear an active
            // persisted session on every ordinary restart.
            merged["CMUX_DEV_AUTH_CREDENTIALS_RESOLVED"] = nil
            merged["CMUX_DEV_AUTH_REPLACE_SESSION"] = nil
        }
        return merged
    }
    #else
    /// In release builds the dogfood auto-sign-in path does not exist; this is
    /// the identity function so production never auto-signs-in.
    nonisolated static func environmentWithDogfoodAutoSignIn(
        _ environment: [String: String]
    ) -> [String: String] {
        environment
    }
    #endif
}
