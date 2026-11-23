import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import Foundation
import Testing

/// When the warm start skips, and what counts as an idle moment. An engine
/// with no embedded runtime is unavailable, so nothing here maps or starts
/// Chromium (the runtime is process-wide).
@MainActor struct ChromiumWarmupTests {
    final class Clock { var now: TimeInterval = 100 }

    let clock = Clock()

    func warmup(trackingMenu: @escaping @MainActor () -> Bool = { false }) -> ChromiumWarmup {
        let clock = clock
        return ChromiumWarmup(engine: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), now: { clock.now }, isTrackingMenu: trackingMenu)
    }

    @Test func anUnavailableEngineNeverWarms() {
        let warmup = warmup()
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.restoredTab)
        #expect(warmup.reason == nil)
    }

    @Test func idleOnceTheQuietPeriodPasses() {
        let warmup = warmup()
        var policy = ChromiumWarmup.Policy()
        policy.idleInput = .milliseconds(750)
        warmup.noteInput()
        clock.now += 0.5
        #expect(!warmup.isIdle(policy))
        clock.now += 0.5
        #expect(warmup.isIdle(policy))
    }

    @Test func inputRestartsTheQuietPeriod() {
        let warmup = warmup()
        let policy = ChromiumWarmup.Policy()
        warmup.noteInput()
        clock.now += 1
        warmup.noteInput()
        #expect(!warmup.isIdle(policy))
    }

    @Test func menuTrackingIsNeverIdle() {
        let warmup = warmup(trackingMenu: { true })
        clock.now += 60
        #expect(!warmup.isIdle(ChromiumWarmup.Policy()))
    }

    /// Chromium starting at launch for agent chats is no reason for a web tab's spare window and page
    /// (Home held both for nothing); any reach for a web tab is.
    @Test func onlyAWebTabSignalMakesTheSpare() {
        #expect(!ChromiumWarmup.signalsWebTab(.launch))
        for reason in [ChromiumWarmup.Reason.restoredTab, .newTabMenu, .palette, .defaultEngine] {
            #expect(ChromiumWarmup.signalsWebTab(reason))
        }
        #expect(!ChromiumWarmup.makesSpare(webTabsOpen: false, webTabIntent: false))
        #expect(ChromiumWarmup.makesSpare(webTabsOpen: true, webTabIntent: false))
        #expect(ChromiumWarmup.makesSpare(webTabsOpen: false, webTabIntent: true))
    }

    /// The load and start steps the warm-up ran, in order.
    final class Steps {
        var log: [String] = []
        var usedRecently = false
    }

    func recordingWarmup(_ steps: Steps) -> ChromiumWarmup {
        let clock = clock
        let loading = ChromiumWarmup.Loading(
            isAvailable: { true },
            preload: { steps.log.append("preload") },
            usedRecently: { _ in steps.log.append("checkedUse"); return steps.usedRecently },
            libraryLoadEnded: {},
            warmStart: { steps.log.append("warmStart:\($0)") })
        return ChromiumWarmup(engine: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()),
                              loading: loading, now: { clock.now }, isTrackingMenu: { false })
    }

    /// Yields the main actor until `done`, at most a bounded number of turns.
    func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    /// Item 6d: with Chromium the default engine, the framework map starts at the first frame (`start` runs from
    /// the first-frame hook), not 3 s later. So does Chromium's start: every cmux page is a Chromium page under
    /// that default, and the first one asked ~420 ms after the frame. CefInitialize runs in a task after the
    /// hook, not inside it.
    @Test func theDefaultEngineMapsAndStartsAtTheFirstFrame() async {
        let steps = Steps()
        let warmup = recordingWarmup(steps)
        warmup.start(defaultIsChromium: { true })
        #expect(steps.log == ["preload"])
        #expect(warmup.reason == .launch)
        await settle { steps.log.count > 1 }
        #expect(steps.log == ["preload", "warmStart:firstFrame"])
        warmup.stop()
    }

    /// The first-frame start is the launch's one warm start: the launch signal `launchPreloadDelay` later, or a
    /// restored tab's, starts nothing again.
    @Test func theFirstFrameStartIsTheOnlyWarmStart() async {
        let steps = Steps()
        let warmup = recordingWarmup(steps)
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.launch)
        warmup.chromiumLikely(.restoredTab)
        await settle { false }
        #expect(steps.log == ["preload", "warmStart:firstFrame"])
        warmup.stop()
    }

    /// Stopped before its task ran (the app began to quit): no start.
    @Test func aStopBeforeTheTaskStartsNothing() async {
        let steps = Steps()
        let warmup = recordingWarmup(steps)
        warmup.start(defaultIsChromium: { true })
        warmup.stop()
        await settle { false }
        #expect(steps.log == ["preload"])
    }

    /// A person who opened a Chromium tab in the last 7 days: the map starts at the first frame, after the
    /// off-main use check.
    @Test func recentUseMapsAtTheFirstFrame() async {
        let steps = Steps()
        steps.usedRecently = true
        let warmup = recordingWarmup(steps)
        warmup.start(defaultIsChromium: { false })
        await settle { steps.log.contains("preload") }
        #expect(steps.log == ["checkedUse", "preload"])
        warmup.stop()
    }

    /// No recent use and WebKit the default: nothing maps (a person who never opens Chromium never pays for it).
    @Test func noRecentUseMapsNothing() async {
        let steps = Steps()
        let warmup = recordingWarmup(steps)
        warmup.start(defaultIsChromium: { false })
        await settle { false }
        #expect(steps.log == ["checkedUse"])
        warmup.stop()
    }

    @Test func theDefaultPolicy() {
        let policy = ChromiumWarmup.Policy()
        #expect(policy.launchPreloadDelay == .seconds(3))
        #expect(policy.idleInput == .milliseconds(750))
        #expect(policy.maxWait == .seconds(60))
        #expect(policy.recentUse == 7 * 24 * 60 * 60)
    }
}
