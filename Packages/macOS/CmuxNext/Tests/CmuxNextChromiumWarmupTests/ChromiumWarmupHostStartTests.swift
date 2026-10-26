import CmuxNextBrowser
import CmuxNextChromiumWarmup
import CmuxNextInputCoreTestSupport
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// p08-startup-046: with the Chromium Host the start runs at once, with no idle wait, once per process;
/// the first spare window still waits for an idle moment.
@MainActor @Suite struct ChromiumWarmupHostStartTests {
    @Test func theHostStartsWithNoIdleWaitAndOnlyOnce() async {
        let engine = StartRecordingEngine()
        let input = FakeInputTap()
        let warmup = ChromiumWarmup(engine: engine, input: input, memory: ManualMemoryLevelRegistry(), clock: ManualClock())

        warmup.startWithoutIdleWait(.restoredTab)
        #expect(input.liveSubscriptions == 0, "the start waited for an idle moment")
        for _ in 0..<1_000 where engine.starts.isEmpty { await Task.yield() }
        #expect(engine.starts == ["restoredTab"])

        warmup.startWithoutIdleWait(.launch)
        warmup.chromiumLikely(.palette)
        for _ in 0..<100 { await Task.yield() }
        #expect(engine.starts == ["restoredTab"], "a second start ran")
        #expect(warmup.reason == .restoredTab)
        #expect(engine.prepared.isEmpty, "the first spare window did not wait for an idle moment")
        warmup.stop()
    }
}

/// Records each warm start (then runs) and each spare step.
@MainActor private final class StartRecordingEngine: ChromiumWarmupEngine {
    var availability: BrowserEngineAvailability = .available
    private(set) var isRunning = false
    private(set) var starts: [String] = []
    private(set) var prepared: [Bool] = []
    let spareWindowCount = 0
    var onSpareWindowNeeded: (@MainActor () -> Void)?

    func usedRecently(within window: TimeInterval) async -> Bool { false }
    func preload() {}
    func libraryLoadEnded() async {}

    func warmStart(reason: String) async {
        starts.append(reason)
        isRunning = true
    }

    func prepareSpareWindow(pages: Bool) -> Bool {
        prepared.append(pages)
        return true
    }

    func dropPagesSpareWindow() {}
    func holdSpareWindows(_ held: Bool) {}
    func closeUntakenSpareWindows() {}
}
