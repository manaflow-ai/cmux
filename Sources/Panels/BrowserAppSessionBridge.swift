import Foundation
import WebKit

@MainActor
final class BrowserAppSessionBridge {
    static let shared = BrowserAppSessionBridge()

    private var generations: [UUID: UInt64] = [:]
    private var handoffStores: [ObjectIdentifier: WKWebsiteDataStore] = [:]

    func beginHandoffNavigationIfNeeded(
        panelID: UUID,
        destinationURL: URL,
        request: URLRequest,
        websiteDataStore: WKWebsiteDataStore,
        navigate: @escaping @MainActor (URLRequest) -> Void
    ) -> Bool {
        generations[panelID, default: 0] &+= 1
        let generation = generations[panelID, default: 0]
        guard request.httpMethod?.uppercased() ?? "GET" == "GET",
              BrowserAppSessionHandoff.shouldHandoff(
                  destinationURL: destinationURL,
                  webOrigin: AuthEnvironment.appWebOrigin
              ) else {
            return false
        }

        handoffStores[ObjectIdentifier(websiteDataStore)] = websiteDataStore
        Task { @MainActor [weak self] in
            guard let self,
                  let tokens = await self.currentNativeTokens(),
                  self.generations[panelID] == generation,
                  let handoffRequest = BrowserAppSessionHandoff.handoffRequest(
                      destinationURL: destinationURL,
                      webOrigin: AuthEnvironment.appWebOrigin,
                      tokens: tokens
                  ) else {
                return
            }
            navigate(handoffRequest)
        }
        return true
    }

    func clearCmuxWebSession() async {
        let stores = trackedWebsiteDataStores()
        for store in stores {
            await clearCmuxWebSession(in: store)
        }
        handoffStores.removeAll()
    }

    private func currentNativeTokens() async -> BrowserAppSessionTokens? {
        guard let coordinator = AppDelegate.shared?.auth?.coordinator else {
            return nil
        }
        if let tokens = try? await coordinator.currentTokens() {
            return BrowserAppSessionTokens(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken
            )
        }
        guard let refreshToken = await coordinator.refreshToken(), !refreshToken.isEmpty else {
            return nil
        }
        let accessToken = await coordinator.storedAccessToken()
        return BrowserAppSessionTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    private func trackedWebsiteDataStores() -> [WKWebsiteDataStore] {
        var stores = handoffStores
        let profileStore = BrowserProfileStore.shared
        stores[ObjectIdentifier(WKWebsiteDataStore.default())] = WKWebsiteDataStore.default()
        for profile in profileStore.profiles {
            let store = profileStore.websiteDataStore(for: profile.id)
            stores[ObjectIdentifier(store)] = store
        }
        return Array(stores.values)
    }

    private func clearCmuxWebSession(in store: WKWebsiteDataStore) async {
        await clearCmuxCookies(in: store.httpCookieStore)
        await clearWebsiteDataRecords(in: store)
    }

    private func clearCmuxCookies(in cookieStore: WKHTTPCookieStore) async {
        let cookies = await allCookies(in: cookieStore)
        let webOrigin = AuthEnvironment.appWebOrigin
        let projectId = AuthEnvironment.stackProjectID
        for cookie in cookies where BrowserAppSessionHandoff.shouldDeleteCookie(
            name: cookie.name,
            domain: cookie.domain,
            webOrigin: webOrigin,
            projectId: projectId
        ) {
            await delete(cookie, from: cookieStore)
        }
    }

    private func clearWebsiteDataRecords(in store: WKWebsiteDataStore) async {
        let records = await dataRecords(in: store)
        guard let host = AuthEnvironment.appWebOrigin.host?.lowercased() else { return }
        let matchingRecords = records.filter { $0.displayName.lowercased() == host }
        guard !matchingRecords.isEmpty else { return }
        await removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            records: matchingRecords,
            from: store
        )
    }

    private func allCookies(in cookieStore: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func delete(_ cookie: HTTPCookie, from cookieStore: WKHTTPCookieStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cookieStore.delete(cookie) {
                continuation.resume()
            }
        }
    }

    private func dataRecords(in store: WKWebsiteDataStore) async -> [WKWebsiteDataRecord] {
        await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                continuation.resume(returning: records)
            }
        }
    }

    private func removeData(
        ofTypes types: Set<String>,
        records: [WKWebsiteDataRecord],
        from store: WKWebsiteDataStore
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, for: records) {
                continuation.resume()
            }
        }
    }
}
