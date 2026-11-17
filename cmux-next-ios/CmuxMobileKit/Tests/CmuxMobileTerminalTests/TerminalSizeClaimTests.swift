import Foundation
import Testing
@testable import CmuxMobileTerminal

/// A page claims its size on the Mac only while it is on screen in the
/// foreground app with nothing over it (PROTOCOL.md, "Terminal size claims").
@Suite struct TerminalSizeClaimDebounceTests {
    typealias Debounce = TerminalSizeClaimDebounce<ContinuousClock.Instant>
    let t0 = ContinuousClock.now

    private func shown() -> Debounce {
        var claim = Debounce(delay: .seconds(1))
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

    /// Leo, 2026-11-14: "we want to bring back the 45 f***ing seconds". The
    /// background keeps the claim for 45 s, then releases.
    @Test func theBackgroundKeepsTheClaimFor45Seconds() {
        var claim = shown()
        claim.appActive = false
        let away = claim.update(at: t0)
        #expect(away.claims == nil, "released at once: coming back inside 45 s would resize the Mac twice")
        #expect(away.recheck == t0.advanced(by: .seconds(45)))
        #expect(claim.update(at: t0.advanced(by: .seconds(44))).claims == nil)
        #expect(claim.update(at: t0.advanced(by: .seconds(45))).claims == false)
        #expect(!claim.claims)
    }

    /// An app switch, or a lock and unlock, inside 45 s: nothing is sent, so
    /// the Mac's pane never resizes and the page never reflows.
    @Test func comingBackInside45SecondsSendsNothing() {
        var claim = shown()
        var sent: [Bool] = []
        for (step, active) in [(1, false), (40, true), (41, false), (42, true)] {
            claim.appActive = active
            if let change = claim.update(at: t0.advanced(by: .seconds(step))).claims { sent.append(change) }
        }
        #expect(sent.isEmpty)
        #expect(claim.claims)
        #expect(claim.releaseAt == nil)
    }

    /// A suspended app runs no timer: coming back after the grace finds the
    /// release overdue. It goes out first (the Mac's lease ended anyway),
    /// then the claim, so the Mac takes the phone's size again.
    @Test func comingBackAfterTheGraceReleasesThenClaims() {
        var claim = shown()
        claim.appActive = false
        _ = claim.update(at: t0)
        claim.appActive = true
        let back = claim.update(at: t0.advanced(by: .seconds(60)))
        #expect(back.claims == false)
        #expect(back.recheck == t0.advanced(by: .seconds(60)))
        #expect(claim.update(at: t0.advanced(by: .seconds(60))).claims == true)
        #expect(claim.claims)
    }

    @Test func aBackgroundDuringAPendingReleaseKeepsItsEarlierDeadline() {
        var claim = shown()
        claim.pageShown = false
        _ = claim.update(at: t0)
        claim.appActive = false
        let away = claim.update(at: t0.advanced(by: .milliseconds(100)))
        #expect(away.claims == nil)
        #expect(away.recheck == t0.advanced(by: .seconds(1)))
        #expect(claim.update(at: t0.advanced(by: .seconds(1))).claims == false)
    }

    /// Back in the app inside the grace, then on another tab: the page's own
    /// 1 s, not what was left of the 45 s.
    @Test func leavingThePageAfterTheForegroundTakesThePageDelay() {
        var claim = shown()
        claim.appActive = false
        _ = claim.update(at: t0)
        claim.appActive = true
        _ = claim.update(at: t0.advanced(by: .seconds(5)))
        claim.pageShown = false
        let left = claim.update(at: t0.advanced(by: .seconds(5)))
        #expect(left.recheck == t0.advanced(by: .seconds(6)))
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
        #expect(claim.update(at: t0.advanced(by: .seconds(45))).claims == false)
        claim.appActive = true
        #expect(claim.update(at: t0.advanced(by: .seconds(46))).claims == true)
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
        // A quick trip to the background sends nothing.
        claimer.set(appActive: false)
        claimer.set(appActive: true)
        #expect(told == [false, true])
    }

    /// A suspended app's release timer never fires; on its return the
    /// overdue release and the claim go out at once, in that order.
    @Test func aClaimerBackAfterTheGraceReleasesThenClaimsAtOnce() {
        let clock = ManualClock()
        var told: [Bool] = []
        let claimer = TerminalSizeClaimer(clock: clock, delay: .seconds(1)) { told.append($0) }
        claimer.set(pageShown: true)
        claimer.set(appActive: false)
        clock.now = clock.now.advanced(by: .seconds(60))
        claimer.set(appActive: true)
        #expect(told == [false, true])
        #expect(claimer.claims)
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

/// A clock that moves only when a test moves it (time as a suspended app
/// sees it: its timers never fire).
private final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now = Instant(offset: .zero)
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        // Never wakes before the test ends: the test calls in itself.
        try await Task.sleep(for: .seconds(3600))
    }
}
