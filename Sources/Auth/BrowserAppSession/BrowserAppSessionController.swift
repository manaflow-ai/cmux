import CmuxAuthRuntime
import CmuxBrowser
import Foundation
import WebKit

/// Exchanges the native Stack session for browser cookies without allowing
/// WebKit navigation to own the exchange lifecycle.
@MainActor
final class BrowserAppSessionController {
    static let appSessionWebsiteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
    private static let webKitCallbackTimeout: Duration = .seconds(5)
    private static let maximumCleanupAttemptsPerOwnership = 2

    private let coordinator: AuthCoordinator
    private let handoff: BrowserAppSessionHandoff
    private let projectID: String
    private let environment: BrowserAppSessionEnvironment
    private let redirectDelegate: BrowserAppSessionRedirectRejectingDelegate
    private let session: URLSession
    private let storeRegistry: BrowserAppSessionStoreRegistry
    private let clearWebsiteDataStore: @MainActor (
        WKWebsiteDataStore
    ) async -> BrowserAppSessionCallbackWaitOutcome
    private var generation: UInt64 = 0
    private var admission = BrowserAppSessionAdmission()
    private var cleanupAttemptCount = 0
    private var activeTasks: [UUID: Task<BrowserAppSessionRequestOutcome, Never>] = [:]
    private var pendingCleanup: (
        id: UUID,
        task: Task<Void, Never>
    )?

    init(
        coordinator: AuthCoordinator,
        webOrigin: URL,
        projectID: String,
        defaults: UserDefaults = .standard,
        storeRegistry registryOverride: BrowserAppSessionStoreRegistry? = nil,
        clearWebsiteDataStore: (@MainActor (
            WKWebsiteDataStore
        ) async -> BrowserAppSessionCallbackWaitOutcome)? = nil
    ) {
        self.coordinator = coordinator
        handoff = BrowserAppSessionHandoff(webOrigin: webOrigin)
        self.projectID = projectID
        let environment = BrowserAppSessionEnvironment(
            webOrigin: webOrigin,
            projectID: projectID
        )
        self.environment = environment
        storeRegistry = registryOverride ?? BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: "cmux.auth.browserAppSessionStores.v2",
            environment: environment,
            legacyDefaultsKeyPrefix: "cmux.auth.browserAppSessionStores."
        )
        self.clearWebsiteDataStore = clearWebsiteDataStore ?? { store in
            await Self.removeAppSessionWebsiteData(from: store)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectDelegate = BrowserAppSessionRedirectRejectingDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    func request(
        destinationURL: URL
    ) async -> BrowserAppSessionRequestOutcome {
        let snapshot: AuthenticatedSessionSnapshot
        do {
            snapshot = try await coordinator.authenticatedSessionSnapshot()
        } catch {
            guard !Task.isCancelled else { return .cancelled }
            return BrowserAppSessionRequestOutcome.tokenFailure(error)
        }
        let expectedOwner = BrowserAppSessionAuthOwner(
            userID: snapshot.accountID,
            authSessionGeneration: snapshot.generation
        )
        if let admittedOwner = admission.owner,
           admittedOwner != expectedOwner {
            beginAuthTransition()
        }
        guard await awaitPendingCleanup() else {
            return .transientFailure
        }
        guard !Task.isCancelled,
              currentAuthOwner == expectedOwner else {
            return .cancelled
        }
        admission.resume(for: expectedOwner)

        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let requestGeneration = generation
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return BrowserAppSessionRequestOutcome.cancelled }
            return await performHandoff(
                destinationURL: destinationURL,
                websiteDataStore: websiteDataStore,
                requestGeneration: requestGeneration,
                snapshot: snapshot
            )
        }
        activeTasks[operationID] = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        activeTasks.removeValue(forKey: operationID)
        return outcome
    }

    func isCurrent(
        generation requestGeneration: UInt64,
        authSessionGeneration: UInt64
    ) -> Bool {
        guard let authOwner = currentAuthOwner else { return false }
        return admission.allows(authOwner)
            && requestGeneration == generation
            && authSessionGeneration == coordinator.authSessionGeneration
    }

    func register(_ panel: BrowserPanel) {
        storeRegistry.register(panel)
    }

    /// Synchronously closes the handoff admission gate before any auth
    /// transition publishes or clears coordinator state. Cleanup runs once and
    /// the next authenticated generation cannot reopen admission until it joins.
    func beginAuthTransition() {
        let hadAdmission = admission.beginTransition()
        guard hadAdmission
                || !activeTasks.isEmpty
                || storeRegistry.hasOwnership else {
            return
        }
        generation &+= 1
        for task in activeTasks.values {
            task.cancel()
        }
        startCleanupIfNeeded()
    }

    func resumeAfterSignIn() async {
        guard let expectedOwner = currentAuthOwner else { return }
        if let admittedOwner = admission.owner,
           admittedOwner != expectedOwner {
            beginAuthTransition()
        }
        guard await awaitPendingCleanup() else { return }
        guard currentAuthOwner == expectedOwner else {
            return
        }
        admission.resume(for: expectedOwner)
    }

    /// Joins cancelled exchanges before deleting the exact stores that received
    /// app-session cookies. No unrelated browser profile is swept.
    func clearCmuxWebSession() async {
        beginAuthTransition()
        _ = await awaitPendingCleanup()
        // A failed physical deletion does not keep the user signed in: live
        // panels already point at fresh stores and admission stays closed while
        // the old store remains owned. A later app-link request gets one retry.
    }

    private var currentAuthOwner: BrowserAppSessionAuthOwner? {
        guard coordinator.isAuthenticated,
              let userID = coordinator.currentUser?.id else {
            return nil
        }
        return BrowserAppSessionAuthOwner(
            userID: userID,
            authSessionGeneration: coordinator.authSessionGeneration
        )
    }

    private func startCleanupIfNeeded() {
        guard pendingCleanup == nil,
              cleanupAttemptCount < Self.maximumCleanupAttemptsPerOwnership else {
            return
        }
        cleanupAttemptCount += 1
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performCleanup()
        }
        pendingCleanup = (id: id, task: task)
    }

    private func awaitPendingCleanup() async -> Bool {
        let hasOwnershipBeforeWait = storeRegistry.hasOwnership
        if !hasOwnershipBeforeWait {
            cleanupAttemptCount = 0
        }
        if admission.owner == nil,
           pendingCleanup == nil,
           hasOwnershipBeforeWait {
            startCleanupIfNeeded()
            guard pendingCleanup != nil else { return false }
        }
        guard let cleanup = pendingCleanup else { return true }
        await cleanup.task.value
        if pendingCleanup?.id == cleanup.id {
            pendingCleanup = nil
        }
        let hasOwnership = storeRegistry.hasOwnership
        if !hasOwnership {
            cleanupAttemptCount = 0
        }
        return !hasOwnership
    }

    private func performCleanup() async {
        let tasks = Array(activeTasks.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = await task.value
        }
        activeTasks.removeAll()

        let panels = storeRegistry.panelsForCleanup()
        for panel in panels {
            panel.resetForAppSessionSignOut()
        }

        let targets = storeRegistry.allEnvironmentStoresForCleanup()
        var cleanupCompleted = true
        for target in targets {
            let outcome = await clearWebsiteDataStore(target.store)
            if outcome != .completed {
                cleanupCompleted = false
            }
        }
        if cleanupCompleted {
            storeRegistry.removeAllOwnership()
        }
        // A failed WebKit callback leaves a weak ownership claim as a
        // fail-closed retry token. The handoff coordinator retries an explicit
        // request once, then uses its normal external recovery path; clearing
        // ownership here would admit new credentials into an uncleared store.
    }

    private func performHandoff(
        destinationURL: URL,
        websiteDataStore: WKWebsiteDataStore,
        requestGeneration: UInt64,
        snapshot: AuthenticatedSessionSnapshot
    ) async -> BrowserAppSessionRequestOutcome {
        guard handoffIsCurrent(
            requestGeneration,
            authSessionGeneration: snapshot.generation
        ) else { return .cancelled }
        guard let exchangeRequest = handoff.request(
            destinationURL: destinationURL,
            tokens: BrowserAppSessionTokens(
                accessToken: snapshot.accessToken,
                refreshToken: snapshot.refreshToken
            )
        ) else { return .failed }

        let response: URLResponse
        do {
            let result = try await session.data(for: exchangeRequest)
            response = result.1
        } catch {
            return handoffIsCurrent(
                requestGeneration,
                authSessionGeneration: snapshot.generation
            ) ? .transientFailure : .cancelled
        }
        guard handoffIsCurrent(
            requestGeneration,
            authSessionGeneration: snapshot.generation
        ) else { return .cancelled }
        guard let httpResponse = response as? HTTPURLResponse else { return .failed }
        if httpResponse.statusCode != 204 {
            return .exchangeFailure(statusCode: httpResponse.statusCode)
        }
        guard let cookies = handoff.sessionCookies(
            from: httpResponse,
            projectID: projectID
        ) else {
            return .failed
        }

        storeRegistry.register(websiteDataStore)
        let clearOutcome = await clearWebsiteDataStore(websiteDataStore)
        guard clearOutcome == .completed else {
            return clearOutcome == .cancelled ? .cancelled : .transientFailure
        }
        guard handoffIsCurrent(
            requestGeneration,
            authSessionGeneration: snapshot.generation
        ) else { return .cancelled }
        for cookie in cookies {
            let setOutcome = await set(
                cookie,
                in: websiteDataStore.httpCookieStore
            )
            guard setOutcome == .completed else {
                return setOutcome == .cancelled ? .cancelled : .transientFailure
            }
            guard handoffIsCurrent(
                requestGeneration,
                authSessionGeneration: snapshot.generation
            ) else { return .cancelled }
        }

        return .navigation(BrowserAppSessionNavigation(
            request: URLRequest(url: destinationURL),
            websiteDataStore: websiteDataStore,
            generation: requestGeneration,
            authSessionGeneration: snapshot.generation
        ))
    }

    private func localHandoffIsCurrent(_ requestGeneration: UInt64) -> Bool {
        guard let authOwner = currentAuthOwner else { return false }
        return admission.allows(authOwner)
            && !Task.isCancelled
            && requestGeneration == generation
    }

    private func handoffIsCurrent(
        _ requestGeneration: UInt64,
        authSessionGeneration: UInt64
    ) -> Bool {
        localHandoffIsCurrent(requestGeneration)
            && authSessionGeneration == coordinator.authSessionGeneration
    }

    private static func removeAppSessionWebsiteData(
        from store: WKWebsiteDataStore
    ) async -> BrowserAppSessionCallbackWaitOutcome {
        await awaitBrowserAppSessionCallback(
            timeout: Self.webKitCallbackTimeout
        ) { completion in
            store.removeData(
                ofTypes: Self.appSessionWebsiteDataTypes,
                modifiedSince: .distantPast
            ) {
                completion()
            }
        }
    }

    private func set(
        _ cookie: HTTPCookie,
        in store: WKHTTPCookieStore
    ) async -> BrowserAppSessionCallbackWaitOutcome {
        await awaitBrowserAppSessionCallback(
            timeout: Self.webKitCallbackTimeout
        ) { completion in
            store.setCookie(cookie) { completion() }
        }
    }
}
