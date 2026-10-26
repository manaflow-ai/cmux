import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import Foundation
import Testing

/// With the Chromium Host, the warmup starts the host right after the first frame while
/// Chromium is the default engine, otherwise on the first Chromium tab; it never maps the
/// framework in cmux, never waits for an idle moment and never makes a spare window.
@MainActor struct ChromiumWarmupHostTests {
    @MainActor final class FakeEngine: ChromiumWarmupEngine {
        var availability: BrowserEngineAvailability = .available
        var isRunning = false
        var onSpareWindowNeeded: (@MainActor () -> Void)?
        private(set) var preloads = 0
        private(set) var warmStarts: [String] = []
        private(set) var spareWindows = 0

        func preload() { preloads += 1 }
        func libraryLoadEnded() async {}
        func usedRecently(within window: TimeInterval) async -> Bool { true }
        func warmStart(reason: String) async { warmStarts.append(reason) }
        func prepareSpareWindow() -> Bool {
            spareWindows += 1
            return true
        }
    }

    let engine = FakeEngine()

    func warmup(_ backend: ChromiumWarmup.Backend) -> ChromiumWarmup {
        ChromiumWarmup(engine: engine, backend: backend, now: { 100 }, isTrackingMenu: { false })
    }

    @Test func chromiumAsDefaultStartsTheHostAtOnce() async {
        let warmup = warmup(.host)
        warmup.start(defaultIsChromium: { true })
        await warmup.hostStart?.value
        #expect(engine.warmStarts == ["launch"])
        #expect(warmup.reason == .launch)
        #expect(engine.preloads == 0)
        #expect(engine.spareWindows == 0)
        #expect(engine.onSpareWindowNeeded == nil)
        warmup.stop()
    }

    @Test func webKitAsDefaultStartsNothingAtLaunch() async {
        let warmup = warmup(.host)
        warmup.start(defaultIsChromium: { false })
        #expect(warmup.hostStart == nil)
        #expect(engine.warmStarts.isEmpty)
        #expect(engine.preloads == 0)
        warmup.stop()
    }

    @Test(arguments: [ChromiumWarmup.Reason.newTabMenu, .palette])
    func aPredictionIsNoTab(reason: ChromiumWarmup.Reason) {
        let warmup = warmup(.host)
        warmup.start(defaultIsChromium: { false })
        warmup.chromiumLikely(reason)
        #expect(warmup.reason == nil)
        #expect(warmup.hostStart == nil)
        #expect(engine.preloads == 0)
        warmup.stop()
    }

    @Test(arguments: [ChromiumWarmup.Reason.restoredTab, .defaultEngine])
    func aChromiumTabOrTheDefaultStartsTheHost(reason: ChromiumWarmup.Reason) async {
        let warmup = warmup(.host)
        warmup.start(defaultIsChromium: { false })
        warmup.chromiumLikely(.palette)
        warmup.chromiumLikely(reason)
        await warmup.hostStart?.value
        #expect(engine.warmStarts == [reason.rawValue])
        #expect(engine.preloads == 0)
        warmup.stop()
    }

    @Test func theHostStartsOnce() async {
        let warmup = warmup(.host)
        warmup.start(defaultIsChromium: { true })
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.restoredTab)
        await warmup.hostStart?.value
        #expect(engine.warmStarts == ["launch"])
        warmup.stop()
    }

    @Test func aRunningHostIsNotStartedAgain() {
        engine.isRunning = true
        let warmup = warmup(.host)
        warmup.start(defaultIsChromium: { true })
        #expect(warmup.hostStart == nil)
        warmup.stop()
    }

    @Test func inProcessStillMapsTheFrameworkAndWantsSpares() {
        let warmup = warmup(.inProcess)
        warmup.start(defaultIsChromium: { false })
        #expect(engine.onSpareWindowNeeded != nil)
        warmup.chromiumLikely(.newTabMenu)
        #expect(warmup.reason == .newTabMenu)
        #expect(engine.preloads == 1)
        #expect(warmup.hostStart == nil)
        warmup.stop()
    }
}
