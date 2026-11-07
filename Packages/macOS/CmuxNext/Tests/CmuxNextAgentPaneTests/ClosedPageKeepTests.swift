import CmuxNextAgentPane
import CmuxNextDesignTokens
import Testing

/// A closed chat's page kept for Reopen Closed (``AgentPageRetirer``): bounded in count and time.
@Suite struct ClosedPageKeepTests {
    final class Page {}

    @Test func aKeptPageComesBackOnceForItsSession() {
        var keep = ClosedPageKeep<Page>(limit: 2)
        let page = Page(), now = ContinuousClock.now
        #expect(keep.keep(page, for: "ses-a", until: now + .seconds(30)).isEmpty)
        #expect(keep.take("ses-b") == nil)
        #expect(keep.take("ses-a") === page)
        #expect(keep.take("ses-a") == nil)
        #expect(keep.isEmpty)
    }

    @Test func theOldestGoesPastTheLimitAndASessionKeepsOnePage() {
        var keep = ClosedPageKeep<Page>(limit: 2)
        let (a, b, c, a2) = (Page(), Page(), Page(), Page())
        let now = ContinuousClock.now
        _ = keep.keep(a, for: "ses-a", until: now + .seconds(30))
        _ = keep.keep(b, for: "ses-b", until: now + .seconds(30))
        let pushed = keep.keep(c, for: "ses-c", until: now + .seconds(30))
        #expect(pushed.count == 1 && pushed[0] === a)
        let replaced = keep.keep(a2, for: "ses-b", until: now + .seconds(30))
        #expect(replaced.count == 1 && replaced[0] === b)
        #expect(keep.take("ses-b") === a2)
    }

    @Test func pagesEndAtTheirDeadlineAndNothingIsKeptAfter() {
        var keep = ClosedPageKeep<Page>(limit: 2)
        let (a, b) = (Page(), Page())
        let now = ContinuousClock.now
        _ = keep.keep(a, for: "ses-a", until: now + .seconds(10))
        _ = keep.keep(b, for: "ses-b", until: now + .seconds(30))
        #expect(keep.soonest == now + .seconds(10))
        let first = keep.expire(at: now + .seconds(10))
        #expect(first.count == 1 && first[0] === a)
        #expect(keep.soonest == now + .seconds(30))
        let second = keep.expire(at: now + .seconds(31))
        #expect(second.count == 1 && second[0] === b)
        #expect(keep.isEmpty && keep.soonest == nil)
    }

    @Test func removeAllEmptiesTheKeep() {
        var keep = ClosedPageKeep<Page>(limit: 2)
        let (a, b) = (Page(), Page())
        let now = ContinuousClock.now
        _ = keep.keep(a, for: "ses-a", until: now + .seconds(30))
        _ = keep.keep(b, for: "ses-b", until: now + .seconds(30))
        let removed = keep.removeAll()
        #expect(removed.count == 2 && removed[0] === a && removed[1] === b)
        #expect(keep.isEmpty && keep.take("ses-a") == nil)
    }

    /// Low Power Mode already on at the close (here the `debug.low_power_mode` override) keeps
    /// nothing: the power observer only reports changes, so the close itself must read the
    /// shared state, not macOS's own flag.
    @MainActor @Test func lowPowerModeOnBeforeTheCloseKeepsNothing() {
        let power = LowPowerMode.system
        let previous = power.override
        power.override = true
        defer { power.override = previous }
        var tornDown: [Page] = []
        let keeper = ClosedPageKeeper<Page>(limit: 2, keepFor: .seconds(30), owner: "ClosedPageKeepTests") { tornDown.append($0) }
        let page = Page()
        #expect(keeper.keep(page, for: "ses-a") == false)
        #expect(keeper.pages.isEmpty)
        #expect(keeper.take("ses-a") == nil)
        // Not kept, so not the keep's to tear down: the retirer tears it down at once.
        #expect(tornDown.isEmpty)
    }
}
