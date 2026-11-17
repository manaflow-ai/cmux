@testable import CmuxNextBrowser
import Foundation
import Testing

/// A frozen hidden chat page gets Chromium's memory purge (`CEFHiddenPageTrim`): one notice per burst of freezes,
/// at most one per minimum gap, nothing reloaded.
@MainActor @Suite struct CEFHiddenPageTrimTests {
    @Test func aBurstWaitsTheDelayAndALaterOneWaitsOutTheGap() {
        let start = ContinuousClock.now
        #expect(CEFHiddenPageTrim.wait(since: nil, now: start) == CEFHiddenPageTrim.delay)
        #expect(CEFHiddenPageTrim.wait(since: start, now: start + .seconds(10)) == CEFHiddenPageTrim.minimumGap - .seconds(10))
        #expect(CEFHiddenPageTrim.wait(since: start, now: start + .seconds(59)) == CEFHiddenPageTrim.delay)
        #expect(CEFHiddenPageTrim.wait(since: start, now: start + .seconds(600)) == CEFHiddenPageTrim.delay)
    }

    @Test func theNoticeIsCriticalAndNoTrimRunsWithoutAFrozenPage() async {
        #expect(CEFHiddenPageTrim.level == "critical")
        var sent = 0
        let trim = CEFHiddenPageTrim { _ in sent += 1 }
        await trim.trim()
        #expect(trim.notices == 0)
        #expect(sent == 0)
    }
}
