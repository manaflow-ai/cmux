@testable import CmuxNextBrowser
import Foundation
import Testing

/// A frozen hidden chat page gets Chromium's memory purge (`CEFHiddenPageTrim`): one notice per burst of freezes,
/// at most one per minimum gap, nothing reloaded.
@MainActor @Suite struct CEFHiddenPageTrimTests {
    @Test func aBurstWaitsTheDelayAndALaterOneWaitsOutTheGap() {
        let start = ContinuousClock.now
        #expect(CEFHiddenPageTrim.nextDelay(since: nil, now: start) == CEFHiddenPageTrim.delay)
        #expect(CEFHiddenPageTrim.nextDelay(since: start, now: start + .seconds(20)) == CEFHiddenPageTrim.minimumGap - .seconds(20))
        #expect(CEFHiddenPageTrim.nextDelay(since: start, now: start + .seconds(55)) == CEFHiddenPageTrim.delay)
        #expect(CEFHiddenPageTrim.nextDelay(since: start, now: start + .seconds(600)) == CEFHiddenPageTrim.delay)
    }

    @Test func theNoticeIsCriticalAndNoTrimRunsWithoutAHiddenPage() async {
        #expect(CEFHiddenPageTrim.level == "critical")
        var sent = 0
        let trim = CEFHiddenPageTrim(hiddenPages: { [] }) { _ in
            sent += 1
            return true
        }
        await trim.trim()
        #expect(trim.notices == 0)
        #expect(sent == 0)
    }
}
