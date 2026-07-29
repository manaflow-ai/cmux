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
    private let handoffStores = NSHashTable<WKWebsiteDataStore>.weakObjects()

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
        handoffStores.add(store)

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
        handoffStores.removeAllObjects()
        for store in stores {
            await clearCmuxWebSession(in: store)
        }
    }

    private func trackedWebsiteDataStores() -> [WKWebsiteDataStore] {
        var stores = Dictionary(
            uniqueKeysWithValues: handoffStores.allObjects.map { store in
                (ObjectIdentifier(store), store)
            }
        )
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
