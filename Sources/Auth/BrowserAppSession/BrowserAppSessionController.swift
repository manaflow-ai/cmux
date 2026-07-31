import CmuxAuthRuntime
import CmuxBrowser
import Foundation
import WebKit

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
