import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import CmuxNextInputCoreTestSupport
import Foundation
import Testing

/// With the Chromium Host the start runs at once, with no idle step, once per process;
/// the first spare window is still an idle step of its own.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ChromiumWarmupHostStartTests {
    @Test func theHostStartsWithNoIdleWaitAndOnlyOnce() async {
        let idle = FakeIdle()
        let engine = FakeWarmupEngine(running: false)
        let warmup = ChromiumWarmup(engine: engine, idle: idle, input: FakeInputTap(), memory: ManualMemoryLevelRegistry(),
                                    isTrackingMenu: { false }, observeMenuEnd: { _ in NSObject() })

        warmup.startWithoutIdleWait(.restoredTab)
        #expect(idle.posts.isEmpty, "the start waited for an idle step")
        for _ in 0..<1_000 where engine.warmStarts.isEmpty { await Task.yield() }
        #expect(engine.warmStarts == ["restoredTab"])
        await idle.posted(1)
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.spare"], "the first spare window is not an idle step")

        warmup.startWithoutIdleWait(.launch)
        warmup.chromiumLikely(.palette)
        for _ in 0..<100 { await Task.yield() }
        #expect(engine.warmStarts == ["restoredTab"], "a second start ran")
        #expect(warmup.reason == .restoredTab)
        #expect(engine.prepared.isEmpty, "the first spare window did not wait for an idle step")
        warmup.stop()
    }
}
