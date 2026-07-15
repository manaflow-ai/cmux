import Foundation
import Testing

@testable import CmuxMobileBrowser

@MainActor
@Suite struct BrowserSurfacePersistenceTests {
    @Test func coldRestoreKeepsWorkspaceAssociationIdentityPageAndSelection() async throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var counter = 0
        let scope = BrowserPersistenceScope(userID: "user-a", teamID: "team-a")
        let firstStore = BrowserSurfaceStore(
            defaultURL: nil,
            makeSurfaceID: {
                counter += 1
                return .init(rawValue: "persisted-\(counter)")
            },
            persistenceDefaults: defaults
        )
        firstStore.setPersistenceScope(scope)
        let first = firstStore.openBrowser(for: "ws-a")
        first.navigationDidFinish(
            url: URL(string: "https://example.com/a")!,
            title: "Workspace A"
        )
        first.setContentModePreference(.desktop)

        let second = firstStore.openBrowser(for: "ws-b")
        second.navigationDidFinish(
            url: URL(string: "https://example.com/b")!,
            title: "Workspace B"
        )
        firstStore.showNonBrowserSurface(for: "ws-b")
        await firstStore.flushPersistence()

        let restored = BrowserSurfaceStore(
            defaultURL: nil,
            makeSurfaceID: { .init(rawValue: "must-not-be-used") },
            persistenceDefaults: defaults
        )
        restored.setPersistenceScope(scope)

        let restoredA = try #require(restored.browser(for: "ws-a"))
        let restoredB = try #require(restored.browser(for: "ws-b"))
        #expect(restoredA.id == .init(rawValue: "persisted-1"))
        #expect(restoredA.currentURL?.absoluteString == "https://example.com/a")
        #expect(restoredA.title == "Workspace A")
        #expect(restoredA.contentModePreference == .desktop)
        #expect(restored.activeBrowser(for: "ws-a") === restoredA)
        #expect(restoredB.id == .init(rawValue: "persisted-2"))
        #expect(restoredB.currentURL?.absoluteString == "https://example.com/b")
        #expect(restoredB.title == "Workspace B")
        #expect(restored.activeBrowser(for: "ws-b") == nil)
        #expect(restoredB.consumeLoadRequest()?.absoluteString == "https://example.com/b")
        #expect(restoredB.canGoBack == false)
        #expect(restoredB.canGoForward == false)
    }

    @Test func coldRestoreUsesCommittedURLBeforeNavigationFinishes() async throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scope = BrowserPersistenceScope(userID: "user-a", teamID: "team-a")
        let store = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        store.setPersistenceScope(scope)
        let browser = store.openBrowser(for: "ws-a")
        browser.navigationDidFinish(url: URL(string: "https://example.com/old")!)
        browser.navigationDidStart()
        browser.navigationDidCommit(url: URL(string: "https://example.com/committed")!)
        await store.flushPersistence()

        let restored = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        restored.setPersistenceScope(scope)

        #expect(restored.browser(for: "ws-a")?.currentURL?.absoluteString ==
            "https://example.com/committed")
    }

    @Test func corruptPersistenceFailsClosedWithoutInventingBrowserIdentity() throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "cmux.mobile.browserSurfaces.v1")

        let store = BrowserSurfaceStore(
            defaultURL: nil,
            makeSurfaceID: { .init(rawValue: "fresh") },
            persistenceDefaults: defaults
        )
        store.setPersistenceScope(.init(userID: "user-a", teamID: "team-a"))

        #expect(store.browser(for: "ws-1") == nil)
        #expect(store.openBrowser(for: "ws-1").id == .init(rawValue: "fresh"))
    }

    @Test func duplicatePersistedRowsRestoreOnlyOneBrowserPerWorkspace() throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshots = [
            BrowserSurfaceSnapshot(
                workspaceID: "ws-1",
                surfaceID: "first",
                currentURL: "https://first.example",
                title: "First",
                contentMode: "recommended",
                isSelected: true
            ),
            BrowserSurfaceSnapshot(
                workspaceID: "ws-1",
                surfaceID: "duplicate",
                currentURL: "https://duplicate.example",
                title: "Duplicate",
                contentMode: "desktop",
                isSelected: false
            ),
        ]
        let scope = BrowserPersistenceScope(userID: "user-a", teamID: "team-a")
        let archive = BrowserSurfaceArchive(scope: scope, surfaces: snapshots)
        defaults.set(try JSONEncoder().encode(archive), forKey: "cmux.mobile.browserSurfaces.v1")

        let store = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        store.setPersistenceScope(scope)
        let restored = try #require(store.browser(for: "ws-1"))

        #expect(restored.id == .init(rawValue: "first"))
        #expect(restored.currentURL?.absoluteString == "https://first.example")
        #expect(store.activeBrowser(for: "ws-1") === restored)
    }

    @Test func persistenceRequiresAnAuthenticatedScope() throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        _ = store.openBrowser(for: "ws-1")

        #expect(defaults.data(forKey: "cmux.mobile.browserSurfaces.v1") == nil)
    }

    @Test func accountOrTeamMismatchFailsClosedAndDeletesOwnerArchive() async throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = BrowserPersistenceScope(userID: "user-a", teamID: "team-a")

        let first = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        first.setPersistenceScope(owner)
        _ = first.openBrowser(for: "ws-1")
        await first.flushPersistence()

        let otherAccount = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        otherAccount.setPersistenceScope(.init(userID: "user-b", teamID: "team-a"))
        #expect(otherAccount.browser(for: "ws-1") == nil)
        #expect(defaults.data(forKey: "cmux.mobile.browserSurfaces.v1") == nil)

        first.setPersistenceScope(owner)
        _ = first.openBrowser(for: "ws-2")
        await first.flushPersistence()
        let otherTeam = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        otherTeam.setPersistenceScope(.init(userID: "user-a", teamID: "team-b"))
        #expect(otherTeam.browser(for: "ws-2") == nil)
        #expect(defaults.data(forKey: "cmux.mobile.browserSurfaces.v1") == nil)
    }

    @Test func scopeTransitionsClearLiveAndDurableBrowserState() async throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scope = BrowserPersistenceScope(userID: "user-a", teamID: "team-a")
        let store = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)

        store.setPersistenceScope(scope)
        let browser = store.openBrowser(for: "ws-1")
        store.setPersistenceScope(scope)
        #expect(store.browser(for: "ws-1") === browser)

        store.setPersistenceScope(.init(userID: "user-a", teamID: "team-b"))
        #expect(store.browser(for: "ws-1") == nil)
        let priorOwnerObserver = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        priorOwnerObserver.setPersistenceScope(scope)
        #expect(priorOwnerObserver.browser(for: "ws-1") == nil)
        await store.flushPersistence()
        #expect(defaults.data(forKey: "cmux.mobile.browserSurfaces.v1") == nil)

        _ = store.openBrowser(for: "ws-2")
        store.setPersistenceScope(nil)
        #expect(store.browser(for: "ws-2") == nil)
        let signedOutObserver = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        signedOutObserver.setPersistenceScope(.init(userID: "user-a", teamID: "team-b"))
        #expect(signedOutObserver.browser(for: "ws-2") == nil)
        await store.flushPersistence()
        #expect(defaults.data(forKey: "cmux.mobile.browserSurfaces.v1") == nil)
    }
}
