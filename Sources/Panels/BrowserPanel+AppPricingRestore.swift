import CmuxAuthRuntime
import CmuxBrowser
import Foundation
import WebKit

@MainActor
final class BrowserAppSessionController {
    private let coordinator: AuthCoordinator
    private let handoff: BrowserAppSessionHandoff
    private let projectID: String
    private var generation: UInt64 = 0
    private var handoffStores: [ObjectIdentifier: WKWebsiteDataStore] = [:]

    init(
        coordinator: AuthCoordinator,
        webOrigin: URL,
        projectID: String
    ) {
        self.coordinator = coordinator
        handoff = BrowserAppSessionHandoff(webOrigin: webOrigin)
        self.projectID = projectID
    }

    func request(
        destinationURL: URL,
        profileID: UUID
    ) async -> URLRequest? {
        let requestGeneration = generation
        let store = BrowserProfileStore.shared.websiteDataStore(for: profileID)
        handoffStores[ObjectIdentifier(store)] = store

        let tokens: BrowserAppSessionTokens?
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
            tokens = nil
        }

        guard requestGeneration == generation, let tokens else { return nil }
        return handoff.request(destinationURL: destinationURL, tokens: tokens)
    }

    func clearCmuxWebSession() async {
        generation &+= 1
        let stores = trackedWebsiteDataStores()
        handoffStores.removeAll()
        for store in stores {
            await clearCmuxWebSession(in: store)
        }
    }

    private func trackedWebsiteDataStores() -> [WKWebsiteDataStore] {
        var stores = handoffStores
        let profileStore = BrowserProfileStore.shared
        stores[ObjectIdentifier(WKWebsiteDataStore.default())] = WKWebsiteDataStore.default()
        stores[ObjectIdentifier(
            profileStore.websiteDataStore(for: profileStore.builtInDefaultProfileID)
        )] = profileStore.websiteDataStore(for: profileStore.builtInDefaultProfileID)
        for profile in profileStore.profiles {
            let store = profileStore.websiteDataStore(for: profile.id)
            stores[ObjectIdentifier(store)] = store
        }
        return Array(stores.values)
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
}

extension BrowserPanel {
    static func remappedAppPricingSessionRestoreURL(_ url: URL?) -> URL? {
        guard let url, isAppPricingURL(url) else { return url }
        guard var components = URLComponents(url: AuthEnvironment.appPricingURL, resolvingAgainstBaseURL: false) else {
            return AuthEnvironment.appPricingURL
        }
        if let restoredComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = restoredComponents.queryItems
            components.fragment = restoredComponents.fragment
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "cmux_app" }
        queryItems.removeAll { $0.name == "cmux_scheme" }
        queryItems.append(URLQueryItem(name: "cmux_app", value: "1"))
        queryItems.append(URLQueryItem(name: "cmux_scheme", value: AuthEnvironment.callbackScheme))
        components.queryItems = queryItems
        return components.url ?? AuthEnvironment.appPricingURL
    }

    private static func isAppPricingURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return url.path == "/app-pricing"
    }
}
