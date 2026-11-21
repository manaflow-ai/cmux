import AppKit
@testable import CmuxNextApp
@testable import CmuxNextCompat
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

    private func slotCount(of counter: PageInstallCounter) -> Int {
        guard let generations = Mirror(reflecting: counter).children.first(where: { $0.label == "generations" })?.value
                as? ObservedMap<String, UInt64> else { return -1 }
        guard let slots = Mirror(reflecting: generations).children.first(where: { $0.label == "slots" })?.value else { return -1 }
        return Mirror(reflecting: slots).children.count
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

    @Test func releasedTabsDropTheirPageInstallSlots() {
        let counter = PageInstallCounter()
        let keys = (0..<1_000).map { "tab-\($0)" }
        for key in keys { counter.bump([key]) }
        #expect(slotCount(of: counter) == keys.count)

        let observed = Counter()
        withObservationTracking({ _ = counter.generation(of: keys[0]) }) {
            observed.value += 1
        }
        counter.forget(keys[0])
        #expect(observed.value == 1, "forget must invalidate a row that observed the released tab")

        for key in keys.dropFirst() { counter.forget(key) }
        #expect(slotCount(of: counter) == 0, "released tabs left page-install generation slots behind")
    }
}
