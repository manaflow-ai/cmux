import CmuxNextCompat
import Foundation
import Testing

/// What the bodies under test saw, in order.
private final class InlineRunLog {
    var events: [String] = []
}

@Suite struct MainThreadInlineRunTests {
    /// On the main thread the body runs before the call returns, once, and the call says so.
    @Test func onTheMainThreadTheBodyRunsInlineOnce() {
        let log = InlineRunLog()
        let ran = MainThreadInlineRun.ifOnMainThread { log.events.append("body") }
        log.events.append("after")
        #expect(ran)
        #expect(log.events == ["body", "after"])
    }

    /// Off the main thread the body does not run, and the call says so.
    @Test func offTheMainThreadTheBodyDoesNotRun() async {
        let log = InlineRunLog()
        let ran = await Task.detached {
            MainThreadInlineRun.ifOnMainThread { log.events.append("body") }
        }.value
        #expect(!ran)
        #expect(log.events.isEmpty)
    }
}
