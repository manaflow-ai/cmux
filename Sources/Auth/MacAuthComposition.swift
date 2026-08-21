import CMUXAuthCore
import CmuxAuthRuntime
import AppKit
import Foundation
import StackAuth

/// The macOS auth composition root.
///
/// Constructs the de-singletonized auth graph, mirroring the iOS
/// `MobileAuthComposition`: the keychain/file fallback token store, a
/// `StackClientApp` over it (wrapped in ``CmuxAuthRuntime/StackAuthClient``),
/// the shared ``CmuxAuthRuntime/AuthCoordinator`` bound to the historical mac
/// defaults keys, and the ``HostBrowserSignInFlow``. Replaces
/// `AuthManager.shared`.
///
/// Built once at app startup, and rebuilt in-process by the live
/// backend-environment switch through ``init(rebinding:environment:defaults:)``,
/// which reuses the existing ``HostAccountFlow`` and hands the fresh graph to
/// `AppDelegate.adoptRebuiltAuth(_:)`.
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

    /// The environment-frozen pieces one build pass produces. Shared by the
    /// startup initializer and the live-switch rebinding initializer so the
    /// graph is constructed identically both times.
    private struct Graph {
        let coordinator: AuthCoordinator
        let callbackRouter: AuthCallbackRouter
        let tokenStore: any StackAuthTokenStoreProtocol
        let browserSignIn: HostBrowserSignInFlow
        let browserAppSession: BrowserAppSessionController
        /// The persisted backend override this pass resolved against.
        let backendEnvironmentOverride: CMUXBackendEnvironmentOverride
    }

    /// Build the auth graph at app startup.
    /// - Parameters:
    ///   - environment: The process environment (UI-test launch options).
    ///   - defaults: Persistence for the cached user / has-tokens flag /
    ///     selected team (historical `cmux.auth.*` keys).
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        let graph = Self.buildGraph(environment: environment, defaults: defaults)
        coordinator = graph.coordinator
        callbackRouter = graph.callbackRouter
        tokenStore = graph.tokenStore
        browserSignIn = graph.browserSignIn
        browserAppSession = graph.browserAppSession
        let accountFlow = HostAccountFlow(
            coordinator: graph.coordinator,
            browserSignIn: graph.browserSignIn,
            activeBackendEnvironmentOverride: graph.backendEnvironmentOverride,
            backendEnvironmentPinnedByLaunchEnvironment:
                HostAccountFlow.launchEnvironmentPinsBackendEnvironment(environment),
            backendEnvironmentDefaults: defaults,
            confirmStagingSignOut: {
                StagingSignOutConfirmationPresenter().confirmStagingSignOut()
            }
        )
        self.accountFlow = accountFlow
        accountFlow.attachBackendEnvironmentSwitchController(
            Self.makeBackendEnvironmentSwitchController(
                accountFlow: accountFlow,
                environment: environment,
                defaults: defaults
            )
        )
    }

    /// Build a fresh auth graph for the (already committed) new backend
    /// environment and rebind the existing ``HostAccountFlow`` to it, instead
    /// of constructing a new flow. Used by the live backend-environment
    /// switch: the flow object, its attached switch controller, and every
    /// Settings view observing it survive; only the environment-frozen graph
    /// underneath is replaced. The fresh ``AuthLaunchOptions`` re-run
    /// ``detectAuthProjectSwitch(resolvedProjectID:buildDefaultProjectID:defaults:)``,
    /// so a project flip primes `clearStaleAuthOnLaunch` on the new
    /// coordinator's `start()`.
    init(
        rebinding accountFlow: HostAccountFlow,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        let graph = Self.buildGraph(environment: environment, defaults: defaults)
        coordinator = graph.coordinator
        callbackRouter = graph.callbackRouter
        tokenStore = graph.tokenStore
        browserSignIn = graph.browserSignIn
        browserAppSession = graph.browserAppSession
        self.accountFlow = accountFlow
        accountFlow.rebind(
            coordinator: graph.coordinator,
            browserSignIn: graph.browserSignIn,
            activeBackendEnvironmentOverride: graph.backendEnvironmentOverride
        )
    }

    /// The production step wiring for the live backend-environment switch.
    /// Every closure resolves the flow's CURRENT graph at run time (weakly,
    /// so the controller the flow owns never retains the flow back), which
    /// keeps a second switch correct after the first rebind.
    private static func makeBackendEnvironmentSwitchController(
        accountFlow: HostAccountFlow,
        environment: [String: String],
        defaults: UserDefaults
    ) -> MacBackendEnvironmentSwitchController {
        MacBackendEnvironmentSwitchController(
            steps: BackendEnvironmentSwitchTransaction.Steps(
                isPinnedByBuild: { [weak accountFlow] in
                    accountFlow?.backendEnvironmentPinnedByLaunchEnvironment ?? true
                },
                activeEnvironment: { [weak accountFlow] in
                    accountFlow?.activeBackendEnvironmentOverride ?? .production
                },
                parkSession: { [weak accountFlow] in
                    // Park under the OLD defaults: HostBrowserSignInFlow
                    // .parkSession() (cancels in-flight sign-in attempts,
                    // clears the cmux web session, detaches the coordinator
                    // session while its token slot survives — NO revocation,
                    // NO iroh binding teardown) plus the flow's Pro-state
                    // reset.
                    await accountFlow?.parkSession()
                },
                quiesce: {
                    // Stop mobile RPC (listener + iroh + caller verification)
                    // so nothing verifies tokens against flipped defaults
                    // while the old coordinator still lives. Restarted by
                    // AppDelegate.adoptRebuiltAuth(_:) after the rebuild.
                    MobileHostService.shared.stop()
                },
                storeOverride: { override in
                    override.store(in: defaults)
                    // EVERY committed override (including a revert's) arms the
                    // one-shot suppression so the immediate rebuild — or the
                    // next launch after a crash — restores the target's PARKED
                    // slot instead of running the organic project-flip clear.
                    CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: defaults)
                },
                rebuild: { [weak accountFlow] _ in
                    guard let accountFlow, let appDelegate = AppDelegate.shared else { return }
                    appDelegate.adoptRebuiltAuth(
                        MacAuthComposition(
                            rebinding: accountFlow,
                            environment: environment,
                            defaults: defaults
                        )
                    )
                },
                awaitRestoredUser: { [weak accountFlow] in
                    // Resolves the CURRENT (rebound) coordinator's launch
                    // restore of the target's parked slot.
                    await accountFlow?.awaitRestoredUser()
                },
                promptSignIn: { [weak accountFlow] in
                    await accountFlow?.promptSignInForBackendSwitch()
                },
                cancelSignInPrompt: { [weak accountFlow] in
                    accountFlow?.cancelBackendSwitchSignInPrompt()
                },
                signOutEstablishedSession: { [weak accountFlow] in
                    // The REAL sign-out chain under the CURRENT (target)
                    // defaults, through the internal direct path that
                    // bypasses the staging sign-out confirmation.
                    await accountFlow?.signOutDirect()
                },
                isEligible: { user in
                    CMUXBackendEnvironmentSwitchGate.allows(user) || Self.isDebugBuild
                },
                signInPromptFailure: { [weak accountFlow] in
                    accountFlow?.backendSwitchSignInPromptFailure() ?? .failed
                }
            )
        )
    }

    /// One environment-frozen build pass over the persisted override.
    private static func buildGraph(
        environment: [String: String],
        defaults: UserDefaults
    ) -> Graph {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        // The persisted backend override resolves ONCE per build pass (at
        // startup, and again when the live switch rebuilds the graph), and
        // replaces only the build-default layer: explicit env (including the
        // LSEnvironment values tagged dev builds bake in) still wins inside
        // every resolved* function.
        let backendEnvironmentOverride = CMUXBackendEnvironmentOverride.load(from: defaults)
        let resolvedAuthEnvironment = AuthEnvironment.resolvedStackAuthEnvironment(
            environment: environment,
            isDebugBuild: Self.isDebugBuild,
            override: backendEnvironmentOverride
        )
        let stackProjectID = AuthEnvironment.resolvedStackProjectID(
            environment: environment,
            isDebugBuild: Self.isDebugBuild,
            override: backendEnvironmentOverride
        )
        let stackPublishableClientKey = AuthEnvironment.resolvedStackPublishableClientKey(
            environment: environment,
            isDebugBuild: Self.isDebugBuild,
            override: backendEnvironmentOverride
        )
        // Per-project token slots: keying the stores by the resolved Stack
        // project lets a live backend-environment switch PARK the old
        // environment's session (its slot survives untouched) and restore it
        // on return. Each store adopts the pre-per-project single slot on
        // first read.
        let tokenStore = FallbackTokenStore(
            primary: KeychainStackTokenStore(
                service: KeychainStackTokenStore.serviceName(bundleIdentifier: bundleIdentifier),
                projectID: stackProjectID
            ),
            fallback: FileStackTokenStore(
                directory: Self.credentialsDirectory(bundleIdentifier: bundleIdentifier),
                projectID: stackProjectID
            )
        )

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
        // detectAuthProjectSwitch must RUN unconditionally (it updates the
        // stored project id); the switch-rebuild marker only suppresses its
        // verdict. A backend-environment switch parks the old session and
        // must restore the target's parked slot, while an organic project
        // flip (rebaked tagged build) keeps today's pinned clear semantics.
        let authProjectSwitched = Self.detectAuthProjectSwitch(
            resolvedProjectID: stackProjectID,
            buildDefaultProjectID: AuthEnvironment.resolvedStackProjectID(
                environment: [:],
                isDebugBuild: Self.isDebugBuild
            ),
            defaults: defaults
        )
        let switchRebuildSuppressesClear =
            CMUXBackendEnvironmentSwitchRebuildMarker.consume(from: defaults)
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
            clearStaleAuthOnLaunch: authProjectSwitched && !switchRebuildSuppressesClear,
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
        let browserAppSession = BrowserAppSessionController(
            coordinator: coordinator,
            webOrigin: AuthEnvironment.appSessionHandoffOrigin,
            projectID: stackProjectID,
            defaults: defaults
        )
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
            // Park (backend-environment switch) clears the browser session
            // like sign-out but must NOT touch iroh: beginSignOutPreparation
            // durably queues a binding revocation, which would kill the
            // parked environment's pairing.
            beginSessionPark: {
                browserAppSession.beginAuthTransition()
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
        return Graph(
            coordinator: coordinator,
            callbackRouter: callbackRouter,
            tokenStore: tokenStore,
            browserSignIn: browserSignIn,
            browserAppSession: browserAppSession,
            backendEnvironmentOverride: backendEnvironmentOverride
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
    /// The persisted backend environment override flows through the same
    /// check: flipping production<->staging flips the resolved Stack project
    /// id, so the next launch wipes the stale session automatically.
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
