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
}

/// Exchanges the native Stack session for browser cookies without allowing
/// WebKit navigation to own the exchange lifecycle.
@MainActor
final class BrowserAppSessionController {
    private let coordinator: AuthCoordinator
    private let handoff: BrowserAppSessionHandoff
    private let projectID: String
    private let session: URLSession
    private var generation: UInt64 = 0
    private var acceptsHandoffs = true
    private var activeTasks: [UUID: Task<BrowserAppSessionRequestOutcome, Never>] = [:]
    private var handoffStores: [ObjectIdentifier: WKWebsiteDataStore] = [:]

    init(
        coordinator: AuthCoordinator,
        webOrigin: URL,
        projectID: String
    ) {
        self.coordinator = coordinator
        handoff = BrowserAppSessionHandoff(webOrigin: webOrigin)
        self.projectID = projectID
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
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

        let stores = Array(handoffStores.values)
        handoffStores.removeAll()
        for store in stores {
            await clearCmuxWebSession(in: store)
        }
    }

    private func performHandoff(
        destinationURL: URL,
        websiteDataStore: WKWebsiteDataStore,
        requestGeneration: UInt64
    ) async -> BrowserAppSessionRequestOutcome {
        let tokens: BrowserAppSessionTokens
        if let current = try? await coordinator.currentTokens() {
            tokens = BrowserAppSessionTokens(
                accessToken: current.accessToken,
                refreshToken: current.refreshToken
            )
        } else if let refreshToken = await coordinator.refreshToken(),
                  !refreshToken.isEmpty {
            tokens = BrowserAppSessionTokens(
                accessToken: await coordinator.storedAccessToken(),
                refreshToken: refreshToken
            )
        } else {
            return coordinator.isAuthenticated ? .failed : .notAuthenticated
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

        handoffStores[ObjectIdentifier(websiteDataStore)] = websiteDataStore
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
