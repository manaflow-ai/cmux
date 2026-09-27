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
        #expect(surface.id == .init(rawValue: "surface-1"))
        #expect(surface.consumeLoadRequest()?.absoluteString == "https://duckduckgo.com/")
    }

    @Test func openBrowserTwiceRevealsSameSurface() {
        let store = makeStore()
        let first = store.openBrowser(for: "ws-1")
        let second = store.openBrowser(for: "ws-1")
        // Same instance, so the current page is restored when switching away and
        // back (the surface's currentURL is reloaded on re-attach). Full live
        // WebKit history persistence across remounts is P2.
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

    @Test func closeBrowserClearsOnlyThatWorkspace() {
        let store = makeStore()
        _ = store.openBrowser(for: "ws-1")
        _ = store.openBrowser(for: "ws-2")
        store.closeBrowser(for: "ws-1")
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
}
