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

/// Persists only the exact WebKit stores that received cmux app-session
/// cookies. Persistent store identifiers survive an app relaunch; ephemeral
/// stores remain process-local because WebKit discards their data on exit.
@MainActor
final class BrowserAppSessionStoreRegistry {
    private let defaults: UserDefaults
    private let defaultsKey: String
    private var liveStores: [ObjectIdentifier: WKWebsiteDataStore] = [:]
    private var identities: Set<BrowserAppSessionStoreIdentity>

    init(defaults: UserDefaults, defaultsKey: String) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        identities = Set(
            (defaults.stringArray(forKey: defaultsKey) ?? []).compactMap(
                BrowserAppSessionStoreIdentity.init(persistedValue:)
            )
        )
    }

    var persistedIdentities: [BrowserAppSessionStoreIdentity] {
        identities.sorted { $0.persistedValue < $1.persistedValue }
    }

    func register(_ store: WKWebsiteDataStore) {
        liveStores[ObjectIdentifier(store)] = store
        guard let identity = Self.identity(for: store),
              identities.insert(identity).inserted else {
            return
        }
        persist()
    }

    func storesForCleanup() -> [WKWebsiteDataStore] {
        var stores = liveStores
        for identity in identities {
            let store = Self.store(for: identity)
            stores[ObjectIdentifier(store)] = store
        }
        return Array(stores.values)
    }

    func removeAllOwnership() {
        liveStores.removeAll()
        identities.removeAll()
        defaults.removeObject(forKey: defaultsKey)
    }

    private func persist() {
        defaults.set(
            persistedIdentities.map(\.persistedValue),
            forKey: defaultsKey
        )
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
        storeRegistry = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: "cmux.auth.browserAppSessionStores.\(projectID)"
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

        let stores = storeRegistry.storesForCleanup()
        for store in stores {
            await clearCmuxWebSession(in: store)
        }
        storeRegistry.removeAllOwnership()
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
        await clearCmuxWebSession(in: websiteDataStore)
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

    private func clearCmuxWebSession(in store: WKWebsiteDataStore) async {
        let cookies = await allCookies(in: store.httpCookieStore)
        for cookie in cookies where handoff.shouldDeleteCookie(
            name: cookie.name,
            domain: cookie.domain,
            projectID: projectID
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
