import AppKit
import CmuxNextBrowserTabs
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Observation
import Testing

/// TYPING FIX 2, F6 follow-up (#31908). An incognito tab's row shows its live page, so its title reads the page-install
/// counter. It read the counter's global `revision`, so every page installed anywhere (an agent's browser tabs in a
/// background workspace) invalidated every incognito row and the next frame mapped them all again. A row must hear
/// its own tab's page install only (CLAUDE.md: a scripted change's local model change is O(changed items)).
@MainActor @Suite(.serialized) struct IncognitoRowPageInstallTests {
    private nonisolated final class Counter: @unchecked Sendable {
        var value = 0
    }

    private func invalidations(_ read: () -> Void, mutate: () -> Void) -> Int {
        let counter = Counter()
        withObservationTracking(read) { counter.value += 1 }
        mutate()
        return counter.value
    }

    @Test func anotherTabsPageInstallDoesNotInvalidateAnIncognitoRow() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .browser, cwd: nil))
        let elsewhere = invalidations({ _ = cache.incognitoDisplay(tab) }, mutate: { cache.pageInstalls.bump(["another-tab"]) })
        #expect(elsewhere == 0, "a page installed in another tab invalidated the incognito row")
        let own = invalidations({ _ = cache.incognitoDisplay(tab) }, mutate: { cache.pageInstalls.bump([tab.id]) })
        #expect(own == 1, "the incognito row did not hear its own tab's page install")
        let closed = invalidations({ _ = cache.incognitoDisplay(tab) }, mutate: { cache.pageInstalls.bump([tab.id], installed: false) })
        #expect(closed == 1, "the incognito row did not hear its own tab's page close")
    }

    @Test func storingOneIncognitoStartURLInvalidatesOnlyThatRow() async throws {
        let daemon = DaemonService()
        let firstSurface = SurfaceID(rawValue: 71)
        let secondSurface = SurfaceID(rawValue: 72)
        let paneID = PaneID(rawValue: 7)
        let workspaceKey = WorkspaceKey(rawValue: "incognito-start-url")
        let pane = PaneSnapshot(id: paneID, tabs: [
            TabSnapshot(surface: firstSurface, kind: .browser, url: BrowserTabService.incognitoPlaceholderURL,
                        browserRenderer: "frontend", browserEngine: "webkit"),
            TabSnapshot(surface: secondSurface, kind: .browser, url: BrowserTabService.incognitoPlaceholderURL,
                        browserRenderer: "frontend", browserEngine: "webkit"),
        ])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 7), layout: .leaf(paneID), panes: [pane])
        let workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 7), key: workspaceKey, name: "incognito", screens: [screen])
        daemon.store.apply(snapshot: DaemonTree(registryID: "incognito-start-url", workspaces: [workspace]))

        let service = BrowserTabService(daemon: daemon,
                                        cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()))
        let surfaces = [firstSurface, secondSurface]
        var nextSurface = 0
        service.create = { _, _, _, _, _, _, _, _ in
            defer { nextSurface += 1 }
            return surfaces[nextSurface]
        }
        let pageInstalls = PageInstallCounter()
        service.onIncognitoStartURLStored = { tabID in
            pageInstalls.bump([tabID], installed: false)
        }
        let firstTab = try #require(daemon.store.tab(surface: firstSurface))
        let secondTab = try #require(daemon.store.tab(surface: secondSurface))

        let firstRow = Counter()
        withObservationTracking({ _ = pageInstalls.generation(of: firstTab.id) }) { firstRow.value += 1 }
        _ = try await service.open(BrowserEngineChoice(engine: .webkit), in: paneID, on: daemon,
                                   url: "https://first.example", incognito: true)
        #expect(firstRow.value == 1, "the row did not hear its own stored start URL")

        let otherTabRow = Counter()
        withObservationTracking({ _ = pageInstalls.generation(of: firstTab.id) }) { otherTabRow.value += 1 }
        _ = try await service.open(BrowserEngineChoice(engine: .webkit), in: paneID, on: daemon,
                                   url: "https://second.example", incognito: true)
        #expect(otherTabRow.value == 0, "another tab's stored start URL invalidated this row")
        #expect(pageInstalls.generation(of: secondTab.id) == 1)
    }
}
