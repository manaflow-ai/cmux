@testable import CmuxNextApp
import CmuxNextCompat
import Foundation
import Testing

/// The git runner never starts its process on the main thread (every-action sweep, other-main-work:
/// screen.close stalled the main thread 807 ms in ProcessMarkdownGitRunner.run at STRESS). Its
/// `run` is a nonisolated async method, so it ran on the caller's actor: the file explorer and the
/// Markdown omnibar call it from the main actor, and `Process.run()` (fork and exec) ran there.
@MainActor @Suite struct MarkdownGitRunnerThreadTests {
    private final class Spawns: Sendable {
        let onMain = Mutex<[Bool]>([])
    }

    @Test func aGitRunCalledFromTheMainActorStartsGitOffTheMainThread() async {
        let spawns = Spawns()
        var runner = ProcessMarkdownGitRunner()
        runner.launch = { process in
            spawns.onMain.withLock { $0.append(Thread.isMainThread) }
            try process.run()
        }
        let output = await runner.run(["--version"], in: "/")
        #expect(output?.status == 0)
        #expect(spawns.onMain.withLock { $0 } == [false], "git was started on the main thread")
    }
}
