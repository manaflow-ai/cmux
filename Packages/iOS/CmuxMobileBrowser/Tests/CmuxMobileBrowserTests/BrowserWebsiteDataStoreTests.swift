#if canImport(WebKit)
import Foundation
import Testing
import WebKit

@testable import CmuxMobileBrowser

@MainActor
@Suite struct BrowserWebsiteDataStoreTests {
    @Test func sameScopeReusesPersistentStoreIdentifier() throws {
        let suiteName = "BrowserWebsiteDataStoreTests.same.\(UUID())"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let scope = BrowserPersistenceScope(userID: "user-a", teamID: "team-a")

        let first = BrowserSurfaceStore(persistenceDefaults: suite)
        first.setPersistenceScope(scope)
        let second = BrowserSurfaceStore(persistenceDefaults: suite)
        second.setPersistenceScope(scope)

        #expect(first.websiteDataStore.identifier != nil)
        #expect(first.websiteDataStore.identifier == second.websiteDataStore.identifier)
    }

    @Test func accountAndTeamChangesUseDifferentPersistentStores() throws {
        let suiteName = "BrowserWebsiteDataStoreTests.scope.\(UUID())"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = BrowserSurfaceStore(persistenceDefaults: suite)

        store.setPersistenceScope(.init(userID: "user-a", teamID: "team-a"))
        let first = try #require(store.websiteDataStore.identifier)
        store.setPersistenceScope(.init(userID: "user-a", teamID: "team-b"))
        let second = try #require(store.websiteDataStore.identifier)
        store.setPersistenceScope(.init(userID: "user-b", teamID: "team-a"))
        let third = try #require(store.websiteDataStore.identifier)

        #expect(first != second)
        #expect(first != third)
        #expect(second != third)
    }

    #if canImport(UIKit)
    @Test func signedOutStoreIsEphemeralAndFlowsIntoWebView() {
        let store = BrowserSurfaceStore()
        #expect(store.websiteDataStore.identifier == nil)

        let state = BrowserSurfaceState(id: .init(rawValue: "signed-out"))
        let webView = MobileBrowserView(
            state: state,
            websiteDataStore: store.websiteDataStore
        ).makeConfiguredWebView()

        #expect(webView.configuration.websiteDataStore === store.websiteDataStore)
        #expect(webView.configuration.websiteDataStore.identifier == nil)
    }
    #endif
}
#endif
