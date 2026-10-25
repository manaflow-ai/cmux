import CmuxNextSignposts
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CoreFoundation
import Darwin
import QuartzCore
import Testing

/// PresentationClock (p04-input 003): presented = the commit's vsync + one render-server frame + the
/// per-OS offset; it holds the window's link only for 3 frames after an input and never makes a link.
@MainActor @Suite(.serialized) struct PresentationClockTests {
    /// A link the fake factory counts.
    @MainActor private final class FakeLink: FrameLink {
        var isPaused = false
        var invalidated = false
        func invalidate() { invalidated = true }
    }

    /// One scheduler with a counting fake link, a clock that never fires its stall timer, and a
    /// presentation clock on a display of the given refresh range.
    @MainActor private final class Rig {
        let scheduler: FrameScheduler
        let clock: PresentationClock
        private let links: LinkBox

        init(minimumRefresh: Double, maximumRefresh: Double? = nil, offsetNanos: Int64 = 0) {
            let links = LinkBox()
            let scheduler = FrameScheduler.testing(clock: ManualClock(), mediaTime: { 1000 }) { _ in
                let link = FakeLink()
                links.made.append(link)
                return link
            }
            let display = PresentationDisplay(minimumRefreshInterval: minimumRefresh,
                                              maximumRefreshInterval: maximumRefresh ?? minimumRefresh)
            self.links = links
            self.scheduler = scheduler
            clock = PresentationClock(offset: PresentationOffset(nanos: offsetNanos), scheduler: { _ in scheduler },
                                      display: { _ in display })
        }

        /// Links the scheduler's factory made.
        var linksMade: Int { links.made.count }

        /// One display frame: link time `seconds`, at `refresh`.
        func frame(at seconds: Double, refresh: Double) {
            scheduler.frameDidFire(timestamp: seconds, refreshInterval: refresh)
        }
    }

    @MainActor private final class LinkBox {
        var made: [FakeLink] = []
    }

    private static func nanos(_ seconds: Double) -> UInt64 { UInt64((seconds * 1e9).rounded()) }

    // MARK: Estimates

    @Test func at60HzACommitIsPresentedOneFrameAfterTheVsyncThatTakesIt() {
        let rig = Rig(minimumRefresh: 1.0 / 60)
        rig.clock.holdForInput(on: rig.scheduler)
        rig.frame(at: 1000, refresh: 1.0 / 60)
        let frame = Self.nanos(1.0 / 60)
        let targetVsync = Self.nanos(1000) + frame
        // A commit 5 ms after the tick is taken by the tick's target vsync.
        let estimate = rig.clock.presented(commitEndNanos: Self.nanos(1000) + 5_000_000, on: rig.scheduler)
        #expect(estimate.nanos == targetVsync + frame)
        #expect(estimate.basis == .heldVsync)
        #expect(estimate.refreshNanos == frame)
        #expect(!estimate.isVariableRefresh)
    }

    @Test func at120HzACommitPastTheTargetGoesToTheNextVsyncPlusTheOffset() {
        let rig = Rig(minimumRefresh: 1.0 / 120, offsetNanos: 1_500_000)
        rig.clock.holdForInput(on: rig.scheduler)
        rig.frame(at: 1000, refresh: 1.0 / 120)
        let frame = Self.nanos(1.0 / 120)
        let targetVsync = Self.nanos(1000) + frame
        // 1 ms after the target vsync: the render server takes it at the vsync after.
        let estimate = rig.clock.presented(commitEndNanos: targetVsync + 1_000_000, on: rig.scheduler)
        #expect(estimate.nanos == targetVsync + frame + frame + 1_500_000)
        #expect(estimate.basis == .heldVsync)
        // A commit exactly on a vsync is taken by that vsync.
        let onVsync = rig.clock.presented(commitEndNanos: targetVsync, on: rig.scheduler)
        #expect(onVsync.nanos == targetVsync + frame + 1_500_000)
    }

    @Test func aNegativeOffsetMovesTheEstimateEarlier() {
        let rig = Rig(minimumRefresh: 1.0 / 60, offsetNanos: -2_000_000)
        rig.clock.holdForInput(on: rig.scheduler)
        rig.frame(at: 1000, refresh: 1.0 / 60)
        let frame = Self.nanos(1.0 / 60)
        let estimate = rig.clock.presented(commitEndNanos: Self.nanos(1000) + 1_000_000, on: rig.scheduler)
        #expect(estimate.nanos == Self.nanos(1000) + frame + frame - 2_000_000)
    }

    @Test func withNoInputTheEstimateExtendsTheLastPhaseWithNoLink() {
        let rig = Rig(minimumRefresh: 1.0 / 120)
        rig.clock.holdForInput(on: rig.scheduler)
        for index in 0..<PresentationClock.holdFrames {
            rig.frame(at: 1000 + Double(index) / 120, refresh: 1.0 / 120)
        }
        #expect(!rig.scheduler.hasLink)
        let frame = Self.nanos(1.0 / 120)
        let lastTarget = Self.nanos(1000 + 2.0 / 120) + frame
        // One second later (120 frames): still on the grid of the last tick, labelled extrapolated.
        let commit = lastTarget + 120 * frame - 3_000_000
        let estimate = rig.clock.presented(commitEndNanos: commit, on: rig.scheduler)
        #expect(estimate.nanos == lastTarget + 120 * frame + frame)
        #expect(estimate.basis == .extrapolated)
        #expect(!rig.scheduler.hasLink)
        #expect(rig.linksMade == 1)
    }

    @Test func aWindowWithNoTickUsesTheNominalRefreshAndStartsNoLink() {
        let rig = Rig(minimumRefresh: 1.0 / 60)
        let commit = Self.nanos(2000)
        let estimate = rig.clock.presented(commitEndNanos: commit, on: rig.scheduler)
        let frame = Self.nanos(1.0 / 60)
        #expect(estimate.nanos == commit + frame / 2 + frame)
        #expect(estimate.basis == .nominal)
        #expect(rig.linksMade == 0)
        #expect(!rig.scheduler.hasLink)
        #expect(rig.scheduler.activeClients.isEmpty)
    }

    // MARK: Holding the link

    @Test func theLinkIsReleasedThreeFramesAfterTheLastInput() {
        let rig = Rig(minimumRefresh: 1.0 / 120)
        rig.clock.holdForInput(on: rig.scheduler)
        #expect(rig.scheduler.hasLink)
        #expect(rig.linksMade == 1)
        rig.frame(at: 1000, refresh: 1.0 / 120)
        rig.frame(at: 1000 + 1.0 / 120, refresh: 1.0 / 120)
        #expect(rig.scheduler.hasLink)
        rig.frame(at: 1000 + 2.0 / 120, refresh: 1.0 / 120)
        #expect(!rig.scheduler.hasLink)
        #expect(rig.scheduler.activeClients.isEmpty)
    }

    @Test func anInputDuringTheHoldRestartsTheThreeFrames() {
        let rig = Rig(minimumRefresh: 1.0 / 120)
        rig.clock.holdForInput(on: rig.scheduler)
        rig.frame(at: 1000, refresh: 1.0 / 120)
        rig.frame(at: 1000 + 1.0 / 120, refresh: 1.0 / 120)
        rig.clock.holdForInput(on: rig.scheduler)
        for index in 2..<4 {
            rig.frame(at: 1000 + Double(index) / 120, refresh: 1.0 / 120)
            #expect(rig.scheduler.hasLink)
        }
        rig.frame(at: 1000 + 4.0 / 120, refresh: 1.0 / 120)
        #expect(!rig.scheduler.hasLink)
        #expect(rig.linksMade == 1)
    }

    @Test func aNewInputAfterTheHoldEndedSubscribesAgainThroughTheScheduler() {
        let rig = Rig(minimumRefresh: 1.0 / 60)
        rig.clock.holdForInput(on: rig.scheduler)
        for index in 0..<PresentationClock.holdFrames {
            rig.frame(at: 1000 + Double(index) / 60, refresh: 1.0 / 60)
        }
        #expect(!rig.scheduler.hasLink)
        rig.clock.holdForInput(on: rig.scheduler)
        #expect(rig.scheduler.hasLink)
        // The scheduler made the link (the factory is its own): the clock made none.
        #expect(rig.linksMade == 2)
        #expect(rig.scheduler.activeClients == ["PresentationClock.hold"])
    }

    @Test func anotherActiveClientKeepsTheLinkAfterTheHold() {
        let rig = Rig(minimumRefresh: 1.0 / 120)
        let spring = FrameClient(owner: "spring", on: rig.scheduler) { _ in true }
        spring.activate()
        rig.clock.holdForInput(on: rig.scheduler)
        for index in 0..<PresentationClock.holdFrames {
            rig.frame(at: 1000 + Double(index) / 120, refresh: 1.0 / 120)
        }
        #expect(rig.scheduler.hasLink)
        #expect(rig.scheduler.activeClients == ["spring"])
        spring.deactivate()
        #expect(!rig.scheduler.hasLink)
    }

    @Test func aStalledFrameEndsTheHoldButIsNotAVsync() {
        let rig = Rig(minimumRefresh: 1.0 / 60)
        rig.clock.holdForInput(on: rig.scheduler)
        for _ in 0..<PresentationClock.holdFrames {
            rig.scheduler.frameDidFire(timestamp: nil, refreshInterval: nil)
        }
        #expect(!rig.scheduler.hasLink)
        let estimate = rig.clock.presented(commitEndNanos: Self.nanos(2000), on: rig.scheduler)
        #expect(estimate.basis == .nominal)
    }

    // MARK: Variable refresh

    @Test func aVariableRefreshDisplayIsLabelled() {
        let rig = Rig(minimumRefresh: 1.0 / 120, maximumRefresh: 1.0 / 48)
        #expect(rig.clock.presented(commitEndNanos: Self.nanos(2000), on: rig.scheduler).isVariableRefresh)
        rig.clock.holdForInput(on: rig.scheduler)
        rig.frame(at: 1000, refresh: 1.0 / 120)
        #expect(rig.clock.presented(commitEndNanos: Self.nanos(1000), on: rig.scheduler).isVariableRefresh)
        #expect(PresentationDisplay(minimumRefreshInterval: 1.0 / 120, maximumRefreshInterval: 1.0 / 48).isVariableRefresh)
        #expect(!PresentationDisplay(minimumRefreshInterval: 1.0 / 60, maximumRefreshInterval: 1.0 / 60).isVariableRefresh)
    }

    @Test func theOffsetIsZeroForAnUncalibratedOS() {
        #expect(PresentationOffset(osMajorVersion: 14).nanos == 0)
    }

    // MARK: Commit end

    /// Runs one main run-loop turn that polls and exits without waiting (as SignpostsTests).
    private func pollingTurn() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        CFRunLoopTimerInvalidate(timer)
    }

    @MainActor private final class Commits {
        var seen: [CommitBoundary.Commit] = []
    }

    @Test func theCommitBoundaryGivesTheCommitEndOnTheUptimeClock() {
        let commits = Commits()
        let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        CommitBoundary().afterCommit { commits.seen.append($0) }
        #expect(commits.seen.isEmpty)
        pollingTurn()
        let after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #expect(commits.seen.count == 1)
        let commit = commits.seen.first
        #expect(commit?.outcome == .committed)
        #expect((commit?.commitEndNanos ?? 0) >= before)
        #expect((commit?.commitEndNanos ?? .max) <= after)
        // CACurrentMediaTime is the same clock: the link's timestamps subtract from it.
        let media = UInt64((CACurrentMediaTime() * 1e9).rounded())
        #expect(media >= (commit?.commitEndNanos ?? .max))
    }
}
