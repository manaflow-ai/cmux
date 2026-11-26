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

    // MARK: - "On iPhone" streamed tabs

    @Test func onDeviceTabRestoresThePhonePageNotTheMacTabURL() {
        let store = makeStore()
        let mac = URL(string: "http://localhost:8765/")
        let first = store.openOnDevice(for: "ws-1", panelID: "panel-1", url: mac)
        #expect(first.linkedStreamPanelID == "panel-1")
        #expect(first.consumeLoadRequest() == mac)
        // The phone navigates on its own.
        first.currentURL = URL(string: "https://example.com/")
        #expect(store.prefersOnDevice(panelID: "panel-1"))

        // Leaving for a terminal closes the pane; coming back reveals the
        // same surface, whose page is the phone's, and loads nothing new.
        store.closeBrowser(for: "ws-1")
        let again = store.openOnDevice(for: "ws-1", panelID: "panel-1", url: mac)
        #expect(again === first)
        #expect(again.consumeLoadRequest() == nil)
        #expect(again.currentURL?.absoluteString == "https://example.com/")
        #expect(store.activeBrowser(for: "ws-1") === first)
    }

    @Test func onDeviceSurfacesAreScopedPerStreamedTab() {
        let store = makeStore()
        let a = store.openOnDevice(for: "ws-1", panelID: "panel-a", url: URL(string: "https://a.test/"))
        let b = store.openOnDevice(for: "ws-1", panelID: "panel-b", url: URL(string: "https://b.test/"))
        #expect(a !== b)
        #expect(store.activeBrowser(for: "ws-1") === b)
        #expect(store.openOnDevice(for: "ws-1", panelID: "panel-a", url: nil) === a)
    }

    @Test func forgettingOnDeviceStartsOverFromTheMacTab() {
        let store = makeStore()
        let first = store.openOnDevice(for: "ws-1", panelID: "panel-1", url: URL(string: "https://mac.test/"))
        store.forgetOnDevice(panelID: "panel-1")
        store.closeBrowser(for: "ws-1")
        #expect(store.prefersOnDevice(panelID: "panel-1") == false)
        let next = store.openOnDevice(for: "ws-1", panelID: "panel-1", url: URL(string: "https://mac.test/b"))
        #expect(next !== first)
        #expect(next.consumeLoadRequest()?.absoluteString == "https://mac.test/b")
    }

    @Test func onDeviceTabWithoutAWebPageLoadsTheDefault() {
        let store = makeStore()
        let surface = store.openOnDevice(for: "ws-1", panelID: "panel-1", url: URL(string: "about:blank"))
        #expect(surface.consumeLoadRequest()?.absoluteString == "https://duckduckgo.com/")
    }
}
