import Foundation
import Testing
@testable import CmuxMobileTerminal

/// A page claims its size on the Mac only while it is on screen in the
/// foreground app with nothing over it (PROTOCOL.md, "Terminal size claims").
@Suite struct TerminalSizeClaimDebounceTests {
    typealias Debounce = TerminalSizeClaimDebounce<ContinuousClock.Instant>
    let t0 = ContinuousClock.now

    private func shown() -> Debounce {
        var claim = Debounce(delay: .seconds(1), backgroundDelay: .seconds(300))
        claim.pageShown = true
        _ = claim.update(at: t0)
        return claim
    }

    @Test func leavingThePageReleasesAfterTheDelay() {
        var claim = shown()
        claim.pageShown = false
        let left = claim.update(at: t0)
        #expect(left.claims == nil, "released at once: a quick switch back would resize the Mac twice")
        #expect(left.recheck == t0.advanced(by: .seconds(1)))
        let later = claim.update(at: t0.advanced(by: .seconds(1)))
        #expect(later.claims == false)
        #expect(!claim.claims)
    }

    @Test func comingBackInsideTheDelayKeepsTheClaimWithoutAChange() {
        var claim = shown()
        claim.pageShown = false
        _ = claim.update(at: t0)
        claim.pageShown = true
        let back = claim.update(at: t0.advanced(by: .milliseconds(300)))
        #expect(back.claims == nil)
        #expect(back.recheck == nil)
        #expect(claim.claims)
        // The release that was due never goes out.
        #expect(claim.update(at: t0.advanced(by: .seconds(2))).claims == nil)
    }

    /// Leo, 2026-11-12: an app switch, the lock screen or a link blip must
    /// not move the Mac's PTY. The background keeps the claim for the grace.
    @Test func theBackgroundKeepsTheClaimForTheGrace() {
        var claim = shown()
        claim.appActive = false
        let away = claim.update(at: t0)
        #expect(away.claims == nil, "released at once: the Mac's PTY grows and the phone redraws twice")
        #expect(away.recheck == t0.advanced(by: .seconds(300)))
        #expect(claim.update(at: t0.advanced(by: .seconds(299))).claims == nil)
        #expect(claim.claims)
        #expect(claim.update(at: t0.advanced(by: .seconds(300))).claims == false)
    }

    /// Background then foreground (an app switch, lock and unlock): nothing
    /// is ever sent, so the Mac never resizes the PTY.
    @Test func backgroundThenForegroundSendsNothing() {
        var claim = shown()
        var sent: [Bool] = []
        for (step, active) in [(1, false), (40, true), (60, false), (200, true)] {
            claim.appActive = active
            if let change = claim.update(at: t0.advanced(by: .seconds(step))).claims { sent.append(change) }
        }
        #expect(sent.isEmpty)
        #expect(claim.claims)
    }

    @Test func aPageThatLeftStillReleasesAfterTheShortDelayInTheBackground() {
        var claim = shown()
        claim.pageShown = false
        _ = claim.update(at: t0)
        claim.appActive = false
        #expect(claim.update(at: t0.advanced(by: .milliseconds(100))).claims == nil)
        #expect(claim.update(at: t0.advanced(by: .seconds(1))).claims == false)
    }

    @Test func thePageLeavingDuringTheBackgroundGraceTakesTheShortDelay() {
        var claim = shown()
        claim.appActive = false
        _ = claim.update(at: t0)
        claim.pageShown = false
        let left = claim.update(at: t0.advanced(by: .seconds(10)))
        #expect(left.recheck == t0.advanced(by: .seconds(11)))
    }

    @Test func aSheetOverThePageReleasesAndItsDismissalClaimsAgain() {
        var claim = shown()
        claim.covered = true
        _ = claim.update(at: t0)
        #expect(claim.update(at: t0.advanced(by: .seconds(1))).claims == false)
        claim.covered = false
        #expect(claim.update(at: t0.advanced(by: .seconds(5))).claims == true)
    }

    @Test func theForegroundClaimsAtOnceWhenThePageIsShown() {
        var claim = shown()
        claim.appActive = false
        _ = claim.update(at: t0)
        // Away past the grace: released; back, it claims at once.
        #expect(claim.update(at: t0.advanced(by: .seconds(300))).claims == false)
        claim.appActive = true
        #expect(claim.update(at: t0.advanced(by: .seconds(301))).claims == true)
    }

    @Test func aPageNeverShownReleasesAfterTheDelay() {
        // A page laid out behind another (a neighbour in the pager) starts
        // claiming, like every session, and gives it up.
        var claim = Debounce(delay: .seconds(1))
        let first = claim.update(at: t0)
        #expect(first.claims == nil)
        #expect(claim.update(at: t0.advanced(by: .seconds(1))).claims == false)
    }
}

@MainActor @Suite struct TerminalSizeClaimerTests {
    @Test func theClaimerTellsTheSessionAfterTheDelay() async throws {
        var told: [Bool] = []
        let claimer = TerminalSizeClaimer(clock: ContinuousClock(), delay: .milliseconds(50)) { told.append($0) }
        claimer.set(pageShown: true)
        claimer.set(pageShown: false)
        #expect(told.isEmpty)
        for _ in 0..<100 where told.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(told == [false])
        claimer.set(pageShown: true)
        #expect(told == [false, true])
        // The background keeps the claim (its grace is long).
        claimer.set(appActive: false)
        #expect(told == [false, true])
        claimer.set(appActive: true)
        #expect(told == [false, true])
    }

    @Test func aClaimerWhosePageNeverShowsReleases() async throws {
        var told: [Bool] = []
        let claimer = TerminalSizeClaimer(clock: ContinuousClock(), delay: .milliseconds(50)) { told.append($0) }
        for _ in 0..<100 where told.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(told == [false])
        _ = claimer
    }

    @Test func aQuickSwitchBackSendsNothing() async throws {
        var told: [Bool] = []
        let claimer = TerminalSizeClaimer(clock: ContinuousClock(), delay: .milliseconds(80)) { told.append($0) }
        claimer.set(pageShown: true)
        for _ in 0..<5 {
            claimer.set(pageShown: false)
            claimer.set(pageShown: true)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(told.isEmpty)
    }
}
