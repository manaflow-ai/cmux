import Foundation
import Testing

@testable import CmuxMobileBrowser

/// The store owns at most one browser surface per workspace and survives Mac
/// re-syncs. These guard the open/reveal/close semantics the shell UI relies on.
@MainActor
@Suite struct BrowserSurfaceStoreTests {
    private func makeStore() -> BrowserSurfaceStore {
        var counter = 0
        return BrowserSurfaceStore(
            defaultURL: URL(string: "https://duckduckgo.com/"),
            makeSurfaceID: {
                counter += 1
                return BrowserSurfaceState.ID(rawValue: "surface-\(counter)")
            }
        )
    }

    @Test func noBrowserByDefault() {
        let store = makeStore()
        #expect(store.hasBrowser(for: "ws-1") == false)
        #expect(store.activeBrowser(for: "ws-1") == nil)
    }

    @Test func openBrowserCreatesSurfaceForWorkspace() {
        let store = makeStore()
        let surface = store.openBrowser(for: "ws-1")
        #expect(store.hasBrowser(for: "ws-1"))
        #expect(store.activeBrowser(for: "ws-1") === surface)
        #expect(store.browser(for: "ws-1") === surface)
        #expect(store.isBrowserSelected(for: "ws-1"))
        #expect(surface.id == .init(rawValue: "surface-1"))
        #expect(surface.consumeLoadRequest()?.absoluteString == "https://duckduckgo.com/")
    }

    @Test func openBrowserTwiceRevealsSameSurface() {
        let store = makeStore()
        let first = store.openBrowser(for: "ws-1")
        let second = store.openBrowser(for: "ws-1")
        // Same instance, so the current page is restored when switching away and
        // back. WebKit session snapshots are stored on that surface across
        // remounts.
        #expect(first === second)
    }

    @Test func browsersAreScopedPerWorkspace() {
        let store = makeStore()
        let a = store.openBrowser(for: "ws-1")
        let b = store.openBrowser(for: "ws-2")
        #expect(a !== b)
        #expect(store.activeBrowser(for: "ws-1") === a)
        #expect(store.activeBrowser(for: "ws-2") === b)
    }

    @Test func selectingTerminalRetainsBrowserIdentityAndSessionState() {
        let store = makeStore()
        let browser = store.openBrowser(for: "ws-1")
        browser.navigationDidFinish(
            url: URL(string: "https://example.com/docs")!,
            title: "Docs"
        )

        store.showNonBrowserSurface(for: "ws-1")

        #expect(store.activeBrowser(for: "ws-1") == nil)
        #expect(store.browser(for: "ws-1") === browser)
        #expect(store.hasBrowser(for: "ws-1"))

        let reopened = store.openBrowser(for: "ws-1")
        #expect(reopened === browser)
        #expect(reopened.id == .init(rawValue: "surface-1"))
        #expect(reopened.currentURL?.absoluteString == "https://example.com/docs")
        #expect(reopened.title == "Docs")
    }

    @Test func workspaceReorderingAndUnrelatedHostStateCannotRetargetBrowsers() {
        let store = makeStore()
        let first = store.openBrowser(for: "ws-1")
        let second = store.openBrowser(for: "ws-2")

        // Lookup order models workspace-list reorder and reconnect refreshes:
        // identity remains keyed only by the remote workspace ID.
        for workspaceID in ["ws-2", "ws-1", "ws-2", "ws-1"] {
            let expected = workspaceID == "ws-1" ? first : second
            #expect(store.browser(for: workspaceID) === expected)
        }
    }

    @Test func closeBrowserClearsOnlyThatWorkspace() {
        let store = makeStore()
        _ = store.openBrowser(for: "ws-1")
        _ = store.openBrowser(for: "ws-2")
        store.closeBrowser(for: "ws-1")
        #expect(store.hasBrowser(for: "ws-1") == false)
        #expect(store.hasBrowser(for: "ws-2"))
    }

    @Test func reconciliationPrunesBrowsersForDeletedWorkspaces() {
        let store = makeStore()
        _ = store.openBrowser(for: "ws-1")
        _ = store.openBrowser(for: "ws-2")

        store.reconcileWorkspaces(["ws-2"])

        #expect(store.hasBrowser(for: "ws-1") == false)
        #expect(store.hasBrowser(for: "ws-2"))
    }

    @Test func reopenAfterCloseMakesFreshSurface() {
        let store = makeStore()
        let first = store.openBrowser(for: "ws-1")
        store.closeBrowser(for: "ws-1")
        let second = store.openBrowser(for: "ws-1")
        #expect(first !== second)
        #expect(second.id == .init(rawValue: "surface-2"))
    }

    @Test func coldRestoreKeepsWorkspaceAssociationIdentityPageAndSelection() throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var counter = 0
        let firstStore = BrowserSurfaceStore(
            defaultURL: nil,
            makeSurfaceID: {
                counter += 1
                return .init(rawValue: "persisted-\(counter)")
            },
            persistenceDefaults: defaults
        )
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

        let restored = BrowserSurfaceStore(
            defaultURL: nil,
            makeSurfaceID: { .init(rawValue: "must-not-be-used") },
            persistenceDefaults: defaults
        )

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
        defaults.set(
            try JSONEncoder().encode(snapshots),
            forKey: "cmux.mobile.browserSurfaces.v1"
        )

        let store = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        let restored = try #require(store.browser(for: "ws-1"))

        #expect(restored.id == .init(rawValue: "first"))
        #expect(restored.currentURL?.absoluteString == "https://first.example")
        #expect(store.activeBrowser(for: "ws-1") === restored)
    }
}
