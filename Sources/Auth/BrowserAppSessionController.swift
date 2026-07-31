import CmuxAuthRuntime
import CmuxBrowser
import Foundation
import WebKit

struct BrowserAppSessionNavigation {
    let request: URLRequest
    let websiteDataStore: WKWebsiteDataStore
    let generation: UInt64
    let authSessionGeneration: UInt64
}

enum BrowserAppSessionRequestOutcome {
    case navigation(BrowserAppSessionNavigation)
    case notAuthenticated
    case cancelled
    case transientFailure
    case failed

    var shouldBeginSignIn: Bool {
        if case .notAuthenticated = self { return true }
        return false
    }

    var shouldRetry: Bool {
        if case .transientFailure = self { return true }
        return false
    }

    static func exchangeFailure(statusCode: Int) -> Self {
        if statusCode == 401 { return .notAuthenticated }
        if (500...599).contains(statusCode) { return .transientFailure }
        return .failed
    }

    static func tokenFailure(_ error: Error) -> Self {
        if let authError = error as? AuthError,
           authError == .unauthorized {
            return .notAuthenticated
        }
        return .transientFailure
    }

    var recoveryAction: BrowserAppSessionRecoveryAction? {
        switch self {
        case .navigation:
            nil
        case .cancelled:
            .isolatedBrowser
        case .notAuthenticated:
            .beginSignIn
        case .transientFailure, .failed:
            .isolatedBrowser
        }
    }
}

enum BrowserAppSessionRecoveryAction: Equatable {
    case beginSignIn
    case isolatedBrowser
}

struct BrowserAppSessionEnvironment: Hashable {
    let webOrigin: URL
    let projectID: String

    init(webOrigin: URL, projectID: String) {
        self.webOrigin = webOrigin
        self.projectID = projectID
    }
}

struct BrowserAppSessionStoreCleanupTarget {
    let store: WKWebsiteDataStore
    let environment: BrowserAppSessionEnvironment
}

final class BrowserAppSessionWeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

/// Tracks only live, isolated WebKit stores that received cmux app-session
/// cookies. Older releases persisted shared profile identifiers; initialization
/// retires those markers without reopening profiles that may now belong to a
/// different web account.
@MainActor
final class BrowserAppSessionStoreRegistry {
    private let environment: BrowserAppSessionEnvironment
    private var liveStores: [
        ObjectIdentifier: BrowserAppSessionWeakReference<WKWebsiteDataStore>
    ] = [:]
    private var livePanels: [
        ObjectIdentifier: BrowserAppSessionWeakReference<BrowserPanel>
    ] = [:]

    init(
        defaults: UserDefaults,
        defaultsKey: String,
        environment: BrowserAppSessionEnvironment,
        legacyDefaultsKeyPrefix: String? = nil
    ) {
        self.environment = environment
        defaults.removeObject(forKey: defaultsKey)
        if let legacyDefaultsKeyPrefix {
            for key in Self.legacyDefaultsKeys(
                defaults: defaults,
                prefix: legacyDefaultsKeyPrefix,
                excluding: defaultsKey
            ) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    func register(_ store: WKWebsiteDataStore) {
        // Credential handoffs must use a dedicated non-persistent store. Never
        // claim or later sweep a user's shared persistent browser profile.
        guard store !== WKWebsiteDataStore.default(), store.identifier == nil else {
            return
        }
        liveStores = liveStores.filter { $0.value.value != nil }
        liveStores[ObjectIdentifier(store)] = BrowserAppSessionWeakReference(store)
    }

    func register(_ panel: BrowserPanel) {
        pruneReleasedOwnership()
        guard liveStores[ObjectIdentifier(panel.websiteDataStore)]?.value != nil else {
            return
        }
        livePanels[ObjectIdentifier(panel)] = BrowserAppSessionWeakReference(panel)
    }

    func panelsForCleanup() -> [BrowserPanel] {
        pruneReleasedOwnership()
        return livePanels.values.compactMap(\.value).filter {
            liveStores[ObjectIdentifier($0.websiteDataStore)]?.value != nil
        }
    }

    func storesForCleanup() -> [WKWebsiteDataStore] {
        var stores: [ObjectIdentifier: WKWebsiteDataStore] = [:]
        for target in allEnvironmentStoresForCleanup() {
            stores[ObjectIdentifier(target.store)] = target.store
        }
        return Array(stores.values)
    }

    func allEnvironmentStoresForCleanup() -> [BrowserAppSessionStoreCleanupTarget] {
        pruneReleasedOwnership()
        var targets: [CleanupTargetIdentity: BrowserAppSessionStoreCleanupTarget] = [:]
        for (identifier, reference) in liveStores {
            if let store = reference.value {
                targets[CleanupTargetIdentity(
                    store: identifier,
                    environment: environment
                )] = BrowserAppSessionStoreCleanupTarget(
                    store: store,
                    environment: environment
                )
            }
        }
        return Array(targets.values)
    }

    func removeAllOwnership() {
        liveStores.removeAll()
        livePanels.removeAll()
    }

    private func pruneReleasedOwnership() {
        liveStores = liveStores.filter { $0.value.value != nil }
        livePanels = livePanels.filter { $0.value.value != nil }
    }

    private static func legacyDefaultsKeys(
        defaults: UserDefaults,
        prefix: String,
        excluding currentKey: String
    ) -> [String] {
        defaults.dictionaryRepresentation().keys.filter {
            $0 != currentKey && $0.hasPrefix(prefix) && $0.count > prefix.count
        }
    }

    private struct CleanupTargetIdentity: Hashable {
        let store: ObjectIdentifier
        let environment: BrowserAppSessionEnvironment
    }
}

final class BrowserAppSessionRedirectRejectingDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Exchanges the native Stack session for browser cookies without allowing
/// WebKit navigation to own the exchange lifecycle.
@MainActor
final class BrowserAppSessionController {
    static let appSessionWebsiteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

    private let coordinator: AuthCoordinator
    private let handoff: BrowserAppSessionHandoff
    private let projectID: String
    private let environment: BrowserAppSessionEnvironment
    private let redirectDelegate: BrowserAppSessionRedirectRejectingDelegate
    private let session: URLSession
    private let storeRegistry: BrowserAppSessionStoreRegistry
    private var generation: UInt64 = 0
    private var acceptsHandoffs = true
    private var activeTasks: [UUID: Task<BrowserAppSessionRequestOutcome, Never>] = [:]

    init(
        coordinator: AuthCoordinator,
        webOrigin: URL,
        projectID: String,
        defaults: UserDefaults = .standard
    ) {
        self.coordinator = coordinator
        handoff = BrowserAppSessionHandoff(webOrigin: webOrigin)
        self.projectID = projectID
        environment = BrowserAppSessionEnvironment(
            webOrigin: webOrigin,
            projectID: projectID
        )
        storeRegistry = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: "cmux.auth.browserAppSessionStores.v2",
            environment: environment,
            legacyDefaultsKeyPrefix: "cmux.auth.browserAppSessionStores."
        )
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
        guard acceptsHandoffs else { return .notAuthenticated }
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let requestGeneration = generation
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return BrowserAppSessionRequestOutcome.cancelled }
            return await performHandoff(
                destinationURL: destinationURL,
                websiteDataStore: websiteDataStore,
                requestGeneration: requestGeneration
            )
        }
        activeTasks[operationID] = task
        let outcome = await task.value
        activeTasks.removeValue(forKey: operationID)
        return outcome
    }

    func isCurrent(
        generation requestGeneration: UInt64,
        authSessionGeneration: UInt64
    ) -> Bool {
        acceptsHandoffs
            && requestGeneration == generation
            && authSessionGeneration == coordinator.authSessionGeneration
    }

    func register(_ panel: BrowserPanel) {
        storeRegistry.register(panel)
    }

    /// Synchronously closes the handoff admission gate and cancels every
    /// exchange before sign-out performs its first await.
    func beginSignOut() {
        acceptsHandoffs = false
        generation &+= 1
        for task in activeTasks.values {
            task.cancel()
        }
    }

    func resumeAfterSignIn() {
        acceptsHandoffs = true
    }

    /// Joins cancelled exchanges before deleting the exact stores that received
    /// app-session cookies. No unrelated browser profile is swept.
    func clearCmuxWebSession() async {
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
        for target in targets {
            await clearCmuxWebSession(in: target.store)
        }
        storeRegistry.removeAllOwnership()
    }

    private func performHandoff(
        destinationURL: URL,
        websiteDataStore: WKWebsiteDataStore,
        requestGeneration: UInt64
    ) async -> BrowserAppSessionRequestOutcome {
        let snapshot: AuthenticatedRefreshTokenSnapshot
        do {
            snapshot = try await coordinator.authenticatedRefreshTokenSnapshot()
        } catch {
            guard localHandoffIsCurrent(requestGeneration) else { return .cancelled }
            return BrowserAppSessionRequestOutcome.tokenFailure(error)
        }

        guard handoffIsCurrent(
            requestGeneration,
            authSessionGeneration: snapshot.generation
        ) else { return .cancelled }
        guard let exchangeRequest = handoff.request(
            destinationURL: destinationURL,
            tokens: BrowserAppSessionTokens(
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
        await clearCmuxWebSession(in: websiteDataStore)
        guard handoffIsCurrent(
            requestGeneration,
            authSessionGeneration: snapshot.generation
        ) else { return .cancelled }
        for cookie in cookies {
            await set(cookie, in: websiteDataStore.httpCookieStore)
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
        acceptsHandoffs && !Task.isCancelled && requestGeneration == generation
    }

    private func handoffIsCurrent(
        _ requestGeneration: UInt64,
        authSessionGeneration: UInt64
    ) -> Bool {
        localHandoffIsCurrent(requestGeneration)
            && authSessionGeneration == coordinator.authSessionGeneration
    }

    private func clearCmuxWebSession(in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { continuation in
            store.removeData(
                ofTypes: Self.appSessionWebsiteDataTypes,
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    private func set(
        _ cookie: HTTPCookie,
        in store: WKHTTPCookieStore
    ) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) { continuation.resume() }
        }
    }
}
