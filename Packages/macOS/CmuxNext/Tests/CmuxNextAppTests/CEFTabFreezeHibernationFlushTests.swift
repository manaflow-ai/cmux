import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextSettings
import Foundation
import Testing

/// p07-memory-101: with `memoryBackForwardCacheFlush` a hidden page empties its back-forward cache once when it
/// freezes, every hidden page that is not frozen once when the memory pressure leaves normal, and a page that hides
/// above normal once at its hide, as Chrome turns the cache off on low memory (`BackForwardCacheMemoryControls`,
/// content/browser/renderer_host/back_forward_cache_impl.cc).
/// A shown page is never flushed. The flushes go through the `backForwardCache` seam's recorder.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct CEFTabFreezeHibernationFlushTests {
    @Test func atWarningEveryHiddenTabFlushesOnceAndTheShownTabNever() {
        let rig = PressureRig(flushes: true)
        rig.hide("a")
        rig.hide("b")
        rig.show("c")

        rig.hibernation.pressureDidChange(.warning)
        #expect(rig.flushes == ["a": 1, "b": 1, "c": 0])

        rig.hibernation.pressureDidChange(.critical)
        #expect(rig.flushes == ["a": 1, "b": 1, "c": 0], "a rise past warning flushed again")

        rig.hibernation.pressureDidChange(.normal)
        #expect(rig.flushes == ["a": 1, "b": 1, "c": 0], "the return to normal flushed")
    }

    /// Normal straight to critical is past warning too; each later rise from normal flushes again.
    @Test func eachRiseFromNormalFlushesTheHiddenTabs() {
        let rig = PressureRig(flushes: true)
        rig.hide("a")
        rig.hibernation.pressureDidChange(.critical)
        #expect(rig.flushes["a"] == 1)
        rig.hibernation.pressureDidChange(.normal)
        rig.hibernation.pressureDidChange(.warning)
        #expect(rig.flushes["a"] == 2)
    }

    /// A tab that hides while the pressure is already above normal flushes in its hide's turn: no pressure edge
    /// comes for it until the pressure is normal again. A hide at normal does not flush.
    @Test func aTabThatHidesAtWarningFlushesOnceAndTheShownTabNever() {
        let rig = PressureRig(flushes: true)
        rig.show("c")
        rig.hibernation.pressureDidChange(.warning)
        #expect(rig.flushes == ["c": 0])

        rig.hide("a")
        #expect(rig.flushes == ["a": 1, "c": 0])

        rig.hibernation.pressureDidChange(.critical)
        #expect(rig.flushes == ["a": 1, "c": 0], "a rise past warning flushed again")

        rig.hibernation.pressureDidChange(.normal)
        rig.hide("b")
        #expect(rig.flushes == ["a": 1, "b": 0, "c": 0], "a hide at normal flushed")
    }

    @Test func withoutTheFeatureAHideAtWarningDoesNotFlush() {
        let rig = PressureRig(flushes: false)
        rig.hibernation.pressureDidChange(.warning)
        rig.hide("a")
        #expect(rig.flushes["a"] == 0)
    }

    @Test func withoutTheFeatureNothingFlushes() {
        let rig = PressureRig(flushes: false)
        rig.hide("a")
        rig.hibernation.pressureDidChange(.warning)
        #expect(rig.flushes["a"] == 0)
    }

    /// One flush at the freeze; the frozen page is not flushed again at warning, since it ran no navigation since.
    @Test func aFreezeFlushesOnceAndAFrozenPageSkipsTheWarningFlush() async throws {
        let rig = try BrowserHibernationTabVisibilityTests.FreezeRig()
        defer { rig.close() }
        let recorder = Flusher()
        rig.hibernation.backForwardCacheFlush.isEnabled = true
        rig.hibernation.backForwardCache = { _ in recorder }
        let key = try await rig.hiddenPage("a")
        try await rig.until("the hidden page freezes") { rig.hibernation.frozen.contains(key) }
        #expect(rig.freezers[key]?.calls == [true])
        #expect(recorder.flushes == 1)

        rig.hibernation.pressureDidChange(.warning)
        #expect(recorder.flushes == 1)
    }

    // MARK: Rig

    /// Records each flush; the page always takes it.
    @MainActor final class Flusher: BrowserBackForwardCacheFlushing {
        private(set) var flushes = 0
        func flushBackForwardCache() -> Bool {
            flushes += 1
            return true
        }
    }

    /// Mock browser tabs in the app's tab content cache, with no freeze (`freezeSeconds` nil).
    @MainActor final class PressureRig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let engine = MockBrowserEngine()
        let pane = NeighborTabsWakeTests.Pane()
        private var flushers: [String: Flusher] = [:]

        init(flushes: Bool) {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines)
            services.cache.hibernation = hibernation
            hibernation.apply(BrowserHibernationSetting(mode: .off, freezeSeconds: nil))
            hibernation.backForwardCacheFlush.isEnabled = flushes
            hibernation.backForwardCache = { [weak self] tab in self?.flushers[tab.id.rawValue] }
        }

        /// Each tab's flush count.
        var flushes: [String: Int] { flushers.mapValues(\.flushes) }

        /// A tab shown once, then hidden.
        func hide(_ key: String) {
            install(key)
            services.cache.present(key, by: pane, presence: .visible)
            services.cache.withdraw(key, by: pane)
        }

        /// A tab the pane shows.
        func show(_ key: String) {
            install(key)
            services.cache.present(key, by: pane, presence: .visible)
        }

        private func install(_ key: String) {
            let tab = engine.makeMockTab(BrowserTabConfiguration(id: BrowserTabID(rawValue: key)))
            flushers[key] = Flusher()
            _ = services.cache.install(tab, for: key)
        }
    }
}
