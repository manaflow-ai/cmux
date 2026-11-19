import Foundation
import Testing
@testable import CmuxNextBrowser

/// NIGHTLY 1.0.0-nightly.4401252575901 crashed (SIGTRAP in `dispatch_assert_queue`, 2026-11-16 20:18) in a staged
/// update's Chromium pre-warm as the app relaunched into the update: the pre-warm's watch on its parent app runs on
/// a background queue, and its handler was a main-actor closure (the module's default isolation), so the runtime's
/// isolation check trapped the moment the parent ended, before `_exit(0)`. The handler must run off the main actor.
@Suite(.timeLimit(.minutes(1))) struct CEFPrewarmParentExitTests {
    @MainActor
    @Test func theParentExitWatchRunsItsEndOffTheMainActor() async throws {
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["0.3"]
        try child.run()
        var watch: (any DispatchSourceProcess)?
        let ended = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            watch = CEFPrewarmSession.watchExit(of: child.processIdentifier) { done.resume(returning: !Thread.isMainThread) }
        }
        watch?.cancel()
        #expect(ended, "the end ran on the main thread; the pre-warm's main thread is held by Chromium's pump")
    }
}
