import AppKit
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
}
