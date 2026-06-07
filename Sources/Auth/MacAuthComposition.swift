import CMUXAuthCore
import CmuxAuthRuntime
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
    /// The hosted-browser sign-in flow (popup + callback URLs + sign-out).
    let browserSignIn: HostBrowserSignInFlow
    /// Recognizes/parses auth callback URLs (AppDelegate URL routing).
    let callbackRouter: AuthCallbackRouter
    /// The token store the Stack client persists through.
    let tokenStore: any StackAuthTokenStoreProtocol

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
        let tokenStore = FallbackTokenStore(
            primary: KeychainStackTokenStore(
                service: KeychainStackTokenStore.serviceName(bundleIdentifier: bundleIdentifier)
            ),
            fallback: FileStackTokenStore(directory: Self.credentialsDirectory(bundleIdentifier: bundleIdentifier))
        )
        self.tokenStore = tokenStore

        let stack = StackClientApp(
            projectId: AuthEnvironment.stackProjectID,
            publishableClientKey: AuthEnvironment.stackPublishableClientKey,
            baseUrl: AuthEnvironment.stackBaseURL.absoluteString,
            tokenStore: .custom(tokenStore),
            noAutomaticPrefetch: true
        )
        let client = StackAuthClient(stack: stack)

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
                projectId: AuthEnvironment.stackProjectID,
                publishableClientKey: AuthEnvironment.stackPublishableClientKey
            ),
            magicLinkCallbackURL: AuthEnvironment.websiteOrigin
                .appendingPathComponent("auth/callback", isDirectory: false)
                .absoluteString,
            apiBaseURL: AuthEnvironment.apiBaseURL.absoluteString
        )
        let launch = AuthLaunchOptions(
            clearAuthRequested: environment["CMUX_UITEST_CLEAR_AUTH"] == "1",
            mockDataEnabled: false,
            environment: environment,
            includesDevAuth: Self.includesDevAuth
        )

        let anchor = AuthPresentationContextProvider()
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
            launch: launch
        )
        self.coordinator = coordinator
        let callbackRouter = AuthCallbackRouter(
            extraAllowedScheme: AuthEnvironment.callbackScheme
        )
        self.callbackRouter = callbackRouter
        self.browserSignIn = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: ASWebBrowserAuthSessionFactory(anchor: anchor),
            callbackRouter: callbackRouter,
            makeSignInURL: { AuthEnvironment.signInURL() },
            callbackScheme: { AuthEnvironment.callbackScheme }
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

    private static var includesDevAuth: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
