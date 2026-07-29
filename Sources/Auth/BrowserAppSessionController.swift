import CmuxAuthRuntime
import CmuxBrowser
import Foundation
import WebKit

struct BrowserAppSessionNavigation {
    let request: URLRequest
    let websiteDataStore: WKWebsiteDataStore
    let generation: UInt64
}

enum BrowserAppSessionRequestOutcome {
    case navigation(BrowserAppSessionNavigation)
    case notAuthenticated
    case failed

    var shouldBeginSignIn: Bool {
        if case .notAuthenticated = self { return true }
        return false
    }

    var shouldRetry: Bool {
        if case .failed = self { return true }
        return false
    }

    static func exchangeFailure(statusCode: Int) -> Self {
        statusCode == 401 ? .notAuthenticated : .failed
    }

    static func tokenFailure(_ error: Error) -> Self {
        if let authError = error as? AuthError,
           authError == .unauthorized {
            return .notAuthenticated
        }
        return .failed
    }

    var recoveryAction: BrowserAppSessionRecoveryAction? {
        switch self {
        case .navigation:
            nil
        case .notAuthenticated:
            .beginSignIn
        case .failed:
            .isolatedBrowser
        }
    }
}

enum BrowserAppSessionRecoveryAction: Equatable {
    case beginSignIn
    case isolatedBrowser
}

enum BrowserAppSessionStoreIdentity: Hashable {
    case defaultStore
    case persistent(UUID)

    fileprivate init?(persistedValue: String) {
        if persistedValue == "default" {
            self = .defaultStore
            return
        }
        guard persistedValue.hasPrefix("persistent:"),
              let identifier = UUID(
                  uuidString: String(persistedValue.dropFirst("persistent:".count))
              ) else {
            return nil
        }
        self = .persistent(identifier)
    }

    fileprivate var persistedValue: String {
        switch self {
        case .defaultStore:
            "default"
        case let .persistent(identifier):
            "persistent:\(identifier.uuidString.lowercased())"
        }
    }
}

struct BrowserAppSessionEnvironment: Hashable {
    let webOrigin: URL
    let projectID: String

    fileprivate init?(webOriginString: String, projectID: String) {
        guard let webOrigin = URL(string: webOriginString),
              !projectID.isEmpty else {
            return nil
        }
        self.webOrigin = webOrigin
        self.projectID = projectID
    }

    init(webOrigin: URL, projectID: String) {
        self.webOrigin = webOrigin
        self.projectID = projectID
    }
}

struct BrowserAppSessionStoreCleanupTarget {
    let store: WKWebsiteDataStore
    let environment: BrowserAppSessionEnvironment
}

private struct BrowserAppSessionStoreOwnership: Hashable {
    let identity: BrowserAppSessionStoreIdentity
    let environment: BrowserAppSessionEnvironment
}

private struct PersistedBrowserAppSessionStoreOwnership: Codable {
    let identity: String
    let webOrigin: String
    let projectID: String
}

final class BrowserAppSessionWeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

/// Persists only the exact WebKit stores that received cmux app-session
/// cookies. Persistent store identifiers survive an app relaunch; ephemeral
/// stores remain process-local because WebKit discards their data on exit.
@MainActor
final class BrowserAppSessionStoreRegistry {
    private let defaults: UserDefaults
    private let defaultsKey: String
    private let environment: BrowserAppSessionEnvironment
    private var liveStores: [
        ObjectIdentifier: BrowserAppSessionWeakReference<WKWebsiteDataStore>
    ] = [:]
    private var ownerships: Set<BrowserAppSessionStoreOwnership>

    init(
        defaults: UserDefaults,
        defaultsKey: String,
        environment: BrowserAppSessionEnvironment,
        legacyDefaultsKeyPrefix: String? = nil
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.environment = environment
        var loadedOwnerships = Self.loadOwnerships(defaults: defaults, key: defaultsKey)
        var legacyKeys: [String] = []
        if let legacyDefaultsKeyPrefix {
            legacyKeys = Self.legacyDefaultsKeys(
                defaults: defaults,
                prefix: legacyDefaultsKeyPrefix,
                excluding: defaultsKey
            )
            for key in legacyKeys {
                let projectID = String(key.dropFirst(legacyDefaultsKeyPrefix.count))
                let legacyEnvironment = BrowserAppSessionEnvironment(
                    webOrigin: environment.webOrigin,
                    projectID: projectID
                )
                loadedOwnerships.append(contentsOf:
                    (defaults.stringArray(forKey: key) ?? []).compactMap { value in
                        BrowserAppSessionStoreIdentity(persistedValue: value).map {
                            BrowserAppSessionStoreOwnership(
                                identity: $0,
                                environment: legacyEnvironment
                            )
                        }
                    }
                )
            }
        }
        ownerships = Set(loadedOwnerships)
        if !legacyKeys.isEmpty {
            persist()
            for key in legacyKeys {
                defaults.removeObject(forKey: key)
            }
        }
    }

    var persistedIdentities: [BrowserAppSessionStoreIdentity] {
        Set(ownerships.map(\.identity)).sorted { $0.persistedValue < $1.persistedValue }
    }

    var hasStaleEnvironmentOwnership: Bool {
        ownerships.contains { $0.environment != environment }
    }

    func register(_ store: WKWebsiteDataStore) {
        liveStores = liveStores.filter { $0.value.value != nil }
        liveStores[ObjectIdentifier(store)] = BrowserAppSessionWeakReference(store)
        guard let identity = Self.identity(for: store),
              ownerships.insert(BrowserAppSessionStoreOwnership(
                  identity: identity,
                  environment: environment
              )).inserted else {
            return
        }
        persist()
    }

    func storesForCleanup() -> [WKWebsiteDataStore] {
        var stores: [ObjectIdentifier: WKWebsiteDataStore] = [:]
        for target in allEnvironmentStoresForCleanup() {
            stores[ObjectIdentifier(target.store)] = target.store
        }
        return Array(stores.values)
    }

    func allEnvironmentStoresForCleanup() -> [BrowserAppSessionStoreCleanupTarget] {
        liveStores = liveStores.filter { $0.value.value != nil }
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
        for ownership in ownerships {
            let store = Self.store(for: ownership.identity)
            targets[CleanupTargetIdentity(
                store: ObjectIdentifier(store),
                environment: ownership.environment
            )] = BrowserAppSessionStoreCleanupTarget(
                store: store,
                environment: ownership.environment
            )
        }
        return Array(targets.values)
    }

    func staleEnvironmentStoresForCleanup() -> [BrowserAppSessionStoreCleanupTarget] {
        allEnvironmentStoresForCleanup().filter { $0.environment != environment }
    }

    func removeStaleEnvironmentOwnership() {
        ownerships = Set(ownerships.filter { $0.environment == environment })
        persist()
    }

    func removeAllOwnership() {
        liveStores.removeAll()
        ownerships.removeAll()
        defaults.removeObject(forKey: defaultsKey)
    }

    private func persist() {
        guard !ownerships.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        let values = ownerships.map {
            PersistedBrowserAppSessionStoreOwnership(
                identity: $0.identity.persistedValue,
                webOrigin: $0.environment.webOrigin.absoluteString,
                projectID: $0.environment.projectID
            )
        }.sorted {
            ($0.projectID, $0.webOrigin, $0.identity) <
                ($1.projectID, $1.webOrigin, $1.identity)
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func loadOwnerships(
        defaults: UserDefaults,
        key: String
    ) -> [BrowserAppSessionStoreOwnership] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode(
                  [PersistedBrowserAppSessionStoreOwnership].self,
                  from: data
              ) else {
            return []
        }
        return values.compactMap { value in
            guard let identity = BrowserAppSessionStoreIdentity(
                persistedValue: value.identity
            ),
                  let environment = BrowserAppSessionEnvironment(
                      webOriginString: value.webOrigin,
                      projectID: value.projectID
                  ) else {
                return nil
            }
            return BrowserAppSessionStoreOwnership(
                identity: identity,
                environment: environment
            )
        }
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

    private static func identity(
        for store: WKWebsiteDataStore
    ) -> BrowserAppSessionStoreIdentity? {
        if store === WKWebsiteDataStore.default() {
            return .defaultStore
        }
        return store.identifier.map(BrowserAppSessionStoreIdentity.persistent)
    }

    private static func store(
        for identity: BrowserAppSessionStoreIdentity
    ) -> WKWebsiteDataStore {
        switch identity {
        case .defaultStore:
            WKWebsiteDataStore.default()
        case let .persistent(identifier):
            WKWebsiteDataStore(forIdentifier: identifier)
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

    var hasStaleEnvironmentOwnership: Bool {
        storeRegistry.hasStaleEnvironmentOwnership
    }

    func request(
        destinationURL: URL,
        websiteDataStore: WKWebsiteDataStore
    ) async -> BrowserAppSessionRequestOutcome {
        guard acceptsHandoffs else { return .failed }
        let requestGeneration = generation
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return BrowserAppSessionRequestOutcome.failed }
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

    func isCurrent(generation requestGeneration: UInt64) -> Bool {
        acceptsHandoffs && requestGeneration == generation
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

        let targets = storeRegistry.allEnvironmentStoresForCleanup()
        for target in targets {
            await clearCmuxWebSession(
                in: target.store,
                environment: target.environment
            )
        }
        storeRegistry.removeAllOwnership()
    }

    /// Deletes app-owned cookies from persisted stores associated with a prior
    /// Stack project or web origin. Ownership is removed only after cleanup, so
    /// an interrupted launch retries instead of forgetting live credentials.
    func clearStaleEnvironmentWebSessions() async {
        let targets = storeRegistry.staleEnvironmentStoresForCleanup()
        for target in targets {
            await clearCmuxWebSession(
                in: target.store,
                environment: target.environment
            )
        }
        storeRegistry.removeStaleEnvironmentOwnership()
    }

    private func performHandoff(
        destinationURL: URL,
        websiteDataStore: WKWebsiteDataStore,
        requestGeneration: UInt64
    ) async -> BrowserAppSessionRequestOutcome {
        let tokens: BrowserAppSessionTokens
        do {
            let current = try await coordinator.currentTokens()
            tokens = BrowserAppSessionTokens(
                accessToken: current.accessToken,
                refreshToken: current.refreshToken
            )
        } catch {
            if BrowserAppSessionRequestOutcome.tokenFailure(error).shouldBeginSignIn {
                return .notAuthenticated
            }
            if let refreshToken = await coordinator.refreshToken(),
               !refreshToken.isEmpty {
                tokens = BrowserAppSessionTokens(
                    accessToken: await coordinator.storedAccessToken(),
                    refreshToken: refreshToken
                )
            } else {
                return .failed
            }
        }

        guard handoffIsCurrent(requestGeneration),
              let exchangeRequest = handoff.request(
                  destinationURL: destinationURL,
                  tokens: tokens
              ) else {
            return .failed
        }

        let response: URLResponse
        do {
            let result = try await session.data(for: exchangeRequest)
            response = result.1
        } catch {
            return .failed
        }
        guard handoffIsCurrent(requestGeneration),
              let httpResponse = response as? HTTPURLResponse else {
            return .failed
        }
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
        await clearCmuxWebSession(
            in: websiteDataStore,
            environment: environment
        )
        guard handoffIsCurrent(requestGeneration) else { return .failed }
        for cookie in cookies {
            await set(cookie, in: websiteDataStore.httpCookieStore)
            guard handoffIsCurrent(requestGeneration) else { return .failed }
        }

        return .navigation(BrowserAppSessionNavigation(
            request: URLRequest(url: destinationURL),
            websiteDataStore: websiteDataStore,
            generation: requestGeneration
        ))
    }

    private func handoffIsCurrent(_ requestGeneration: UInt64) -> Bool {
        acceptsHandoffs && !Task.isCancelled && requestGeneration == generation
    }

    private func clearCmuxWebSession(
        in store: WKWebsiteDataStore,
        environment: BrowserAppSessionEnvironment
    ) async {
        let environmentHandoff = BrowserAppSessionHandoff(
            webOrigin: environment.webOrigin
        )
        let cookies = await allCookies(in: store.httpCookieStore)
        for cookie in cookies where environmentHandoff.shouldDeleteCookie(
            name: cookie.name,
            domain: cookie.domain,
            projectID: environment.projectID
        ) {
            await delete(cookie, from: store.httpCookieStore)
        }
    }

    private func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func delete(
        _ cookie: HTTPCookie,
        from store: WKHTTPCookieStore
    ) async {
        await withCheckedContinuation { continuation in
            store.delete(cookie) { continuation.resume() }
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
