import Foundation
import WebKit

@MainActor
final class BrowserAppSessionBridge {
    static let shared = BrowserAppSessionBridge()

    // Per-panel navigation counter: a newer navigation in the same panel
    // invalidates an in-flight handoff so it can't override the newer load.
    private var navGenerations: [UUID: UInt64] = [:]
    // Bumped whenever the cmux web session is cleared (sign-out / account
    // switch); resets which data stores are considered primed.
    private var signInGeneration: UInt64 = 0
    // Data store -> the signInGeneration it was primed for. A store primed for
    // the current generation navigates normally (its cookies are already set),
    // so the handoff runs at most once per data store per sign-in.
    private var handoffDoneStores: [ObjectIdentifier: UInt64] = [:]
    // Stores with an in-flight handoff, so concurrent navigations don't mint
    // duplicate server-side sessions.
    private var handoffInFlight: Set<ObjectIdentifier> = []
    private var handoffStores: [ObjectIdentifier: WKWebsiteDataStore] = [:]

    func beginHandoffNavigationIfNeeded(
        panelID: UUID,
        destinationURL: URL,
        request: URLRequest,
        websiteDataStore: WKWebsiteDataStore,
        navigate: @escaping @MainActor (URLRequest) -> Void
    ) -> Bool {
        navGenerations[panelID, default: 0] &+= 1
        let navGeneration = navGenerations[panelID, default: 0]
        guard request.httpMethod?.uppercased() ?? "GET" == "GET",
              BrowserAppSessionHandoff.shouldHandoff(
                  destinationURL: destinationURL,
                  webOrigin: AuthEnvironment.appWebOrigin
              ) else {
            return false
        }

        let storeKey = ObjectIdentifier(websiteDataStore)
        // Already primed for this sign-in, or a handoff is already running for
        // this store: navigate normally (existing cookies authenticate).
        if handoffDoneStores[storeKey] == signInGeneration { return false }
        if handoffInFlight.contains(storeKey) { return false }

        handoffInFlight.insert(storeKey)
        handoffStores[storeKey] = websiteDataStore
        let signInGen = signInGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.handoffInFlight.remove(storeKey) }
            // Superseded by a newer navigation in this panel: drop silently
            // (the newer navigation owns the webview now).
            guard self.navGenerations[panelID] == navGeneration else { return }
            guard self.signInGeneration == signInGen,
                  let tokens = await self.currentNativeTokens(),
                  self.navGenerations[panelID] == navGeneration,
                  self.signInGeneration == signInGen,
                  let handoffRequest = BrowserAppSessionHandoff.handoffRequest(
                      destinationURL: destinationURL,
                      webOrigin: AuthEnvironment.appWebOrigin,
                      tokens: tokens
                  ) else {
                // No session available (signed out) or a stale generation: load
                // the original request so the page still renders instead of
                // leaving the webview blank. Do not mark the store primed, so a
                // later sign-in retries the handoff.
                if self.navGenerations[panelID] == navGeneration {
                    navigate(request)
                }
                return
            }
            self.handoffDoneStores[storeKey] = signInGen
            navigate(handoffRequest)
        }
        return true
    }

    func clearCmuxWebSession() async {
        // Invalidate every primed store so the next cmux-origin navigation
        // re-runs the handoff with whatever session is current.
        signInGeneration &+= 1
        handoffDoneStores.removeAll()
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
