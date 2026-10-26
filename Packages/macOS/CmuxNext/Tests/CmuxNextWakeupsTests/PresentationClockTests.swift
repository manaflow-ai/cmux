import CmuxNextSignposts
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CoreFoundation
import Darwin
import QuartzCore
import Testing

/// PresentationClock (p04-input 003): presented = the commit's vsync + one render-server frame + the
/// per-OS offset, resolved by the first real tick after the commit (production order: input, commit,
/// then the held tick); it holds the window's link only for 3 frames after an input and never makes a link.
@MainActor @Suite(.serialized) struct PresentationClockTests {
    /// A link the fake factory counts.
    @MainActor private final class FakeLink: FrameLink {
        var isPaused = false
        var invalidated = false
        func invalidate() { invalidated = true }
    }

    /// One scheduler with a counting fake link, a clock that never fires its stall timer, and a
    /// presentation clock on a display of the given refresh range (``display`` can change).
    @MainActor private final class Rig {
        let scheduler: FrameScheduler
        let clock: PresentationClock
        private let links: LinkBox
        private let screen: DisplayBox
        private let estimates = EstimateBox()

        init(minimumRefresh: Double, maximumRefresh: Double? = nil, offsetNanos: Int64 = 0) {
            let links = LinkBox()
            let scheduler = FrameScheduler.testing(clock: ManualClock(), mediaTime: { 1000 }) { _ in
                let link = FakeLink()
                links.made.append(link)
                return link
            }
            let screen = DisplayBox(PresentationDisplay(displayID: 1, minimumRefreshInterval: minimumRefresh,
                                                        maximumRefreshInterval: maximumRefresh ?? minimumRefresh))
            self.links = links
            self.screen = screen
            self.scheduler = scheduler
            clock = PresentationClock(offset: PresentationOffset(nanos: offsetNanos), scheduler: { _ in scheduler },
                                      display: { _ in screen.display })
        }

        /// Links the scheduler's factory made.
        var linksMade: Int { links.made.count }

        /// The estimates resolved so far, in order.
        var resolved: [PresentedEstimate] { estimates.seen }

        /// The display the window is on now.
        var display: PresentationDisplay {
            get { screen.display }
            set { screen.display = newValue }
        }

        /// One display frame: link time `seconds`, at `refresh`; shown at `target` (default one frame later).
        func frame(at seconds: Double, refresh: Double, target: Double? = nil) {
            scheduler.frameDidFire(timestamp: seconds, refreshInterval: refresh, targetTimestamp: target)
        }

        /// A commit that ended at `nanos`, as the input tracker reports it at the commit boundary.
        func commit(_ nanos: UInt64) {
            let estimates = estimates
            clock.presented(commitEndNanos: nanos, on: scheduler) { estimates.seen.append($0) }
        }

        /// One key at `seconds` at `refresh`: the hold, the key's commit 1 ms before the first
        /// tick, then the hold's ticks.
        func typedKey(at seconds: Double, refresh: Double) {
            clock.holdForInput(on: scheduler)
            commit(PresentationClockTests.nanos(seconds) - 1_000_000)
            for index in 0..<PresentationClock.holdFrames {
                frame(at: seconds + Double(index) * refresh, refresh: refresh)
            }
        }
    }

    @MainActor private final class LinkBox {
        var made: [FakeLink] = []
    }

    @MainActor private final class DisplayBox {
        var display: PresentationDisplay
        init(_ display: PresentationDisplay) { self.display = display }
    }

    @MainActor private final class EstimateBox {
        var seen: [PresentedEstimate] = []
    }

    fileprivate static func nanos(_ seconds: Double) -> UInt64 { UInt64((seconds * 1e9).rounded()) }

    // MARK: Estimates

    @Test func at60HzACommitIsResolvedByTheHeldTickThatFollowsIt() {
        let rig = Rig(minimumRefresh: 1.0 / 60)
        rig.clock.holdForInput(on: rig.scheduler)
        rig.commit(Self.nanos(1000) + 5_000_000)
        // The commit ends before the hold's first tick: nothing is known yet.
        #expect(rig.resolved.isEmpty)
        rig.frame(at: 1000, refresh: 1.0 / 60)
        let frame = Self.nanos(1.0 / 60)
        let targetVsync = Self.nanos(1000 + 1.0 / 60)
        // The commit, 5 ms after the tick's vsync, is taken by the tick's target vsync.
        #expect(rig.resolved.count == 1)
        #expect(rig.resolved.first?.nanos == targetVsync + frame)
        #expect(rig.resolved.first?.basis == .heldVsync)
        #expect(rig.resolved.first?.refreshNanos == frame)
        #expect(rig.resolved.first?.isVariableRefresh == false)
    }

    @Test func at120HzACommitPastTheTargetGoesToTheNextVsyncPlusTheOffset() {
        let rig = Rig(minimumRefresh: 1.0 / 120, offsetNanos: 1_500_000)
        let frame = Self.nanos(1.0 / 120)
        let targetVsync = Self.nanos(1000 + 1.0 / 120)
        rig.clock.holdForInput(on: rig.scheduler)
        // 1 ms after the target vsync: the render server takes it at the vsync after.
        rig.commit(targetVsync + 1_000_000)
        // A commit exactly on a vsync is taken by that vsync.
        rig.commit(targetVsync)
        #expect(rig.resolved.isEmpty)
        rig.frame(at: 1000, refresh: 1.0 / 120)
        #expect(rig.resolved.map(\.nanos) == [targetVsync + frame + frame + 1_500_000, targetVsync + frame + 1_500_000])
        #expect(rig.resolved.allSatisfy { $0.basis == .heldVsync })
    }

    @Test func theHeldTickIsReadAtItsTargetTimestamp() {
        let rig = Rig(minimumRefresh: 1.0 / 120, maximumRefresh: 1.0 / 24)
        rig.clock.holdForInput(on: rig.scheduler)
        rig.commit(Self.nanos(1000) + 1_000_000)
        // A variable-refresh link whose target is 12 ms out, off the timestamp + interval grid: the
        // commit snaps onto the target's grid (12 - 8.33 = 3.67 ms) and shows one frame later, at the target.
        rig.frame(at: 1000, refresh: 1.0 / 120, target: 1000.012)
        #expect(rig.resolved.first?.nanos == Self.nanos(1000.012))
        #expect(rig.resolved.first?.basis == .heldVsync)
        #expect(rig.resolved.first?.isVariableRefresh == true)
    }

    @Test func aNegativeOffsetMovesTheEstimateEarlier() {
        let rig = Rig(minimumRefresh: 1.0 / 60, offsetNanos: -2_000_000)
        rig.clock.holdForInput(on: rig.scheduler)
        rig.commit(Self.nanos(1000) + 1_000_000)
        rig.frame(at: 1000, refresh: 1.0 / 60)
        let frame = Self.nanos(1.0 / 60)
        #expect(rig.resolved.first?.nanos == Self.nanos(1000 + 1.0 / 60) + frame - 2_000_000)
    }

    @Test func aKeyAfterAnIdleLinkDoesNotResolveFromThePreviousPhase() {
        let rig = Rig(minimumRefresh: 1.0 / 120, maximumRefresh: 1.0 / 24)
        rig.typedKey(at: 1000, refresh: 1.0 / 120)
        #expect(!rig.scheduler.hasLink)
        #expect(rig.resolved.count == 1)
        // 125 ms later (typing speed) the next key: its commit waits for the new hold's tick even
        // though an old phase is known, and the panel's phase moved meanwhile (variable refresh).
        rig.clock.holdForInput(on: rig.scheduler)
        rig.commit(Self.nanos(1000.125))
        #expect(rig.resolved.count == 1)
        let tick = 1000.122
        rig.frame(at: tick, refresh: 1.0 / 120)
        let frame = Self.nanos(1.0 / 120)
        #expect(rig.resolved.last?.nanos == Self.nanos(tick + 1.0 / 120) + frame)
        #expect(rig.resolved.last?.basis == .heldVsync)
    }

    @Test func withNoInputTheEstimateExtendsTheLastPhaseWithNoLink() {
        let rig = Rig(minimumRefresh: 1.0 / 120)
        rig.typedKey(at: 1000, refresh: 1.0 / 120)
        #expect(!rig.scheduler.hasLink)
        let frame = Self.nanos(1.0 / 120)
        let lastTarget = Self.nanos(1000 + 2.0 / 120 + 1.0 / 120)
        // Half a second later (60 frames): still on the grid of the last tick, labelled extrapolated.
        let commit = lastTarget + 60 * frame - 3_000_000
        let estimate = rig.clock.presented(commitEndNanos: commit, on: rig.scheduler)
        #expect(estimate.nanos == lastTarget + 60 * frame + frame)
        #expect(estimate.basis == .extrapolated)
        // The resolving form with no running link resolves at once, the same way, and starts nothing.
        rig.commit(commit)
        #expect(rig.resolved.last == estimate)
        #expect(!rig.scheduler.hasLink)
        #expect(rig.linksMade == 1)
    }

    @Test func aPhaseOlderThanTheLimitIsNotExtended() {
        let rig = Rig(minimumRefresh: 1.0 / 120)
        rig.typedKey(at: 1000, refresh: 1.0 / 120)
        let lastTarget = Self.nanos(1000 + 2.0 / 120 + 1.0 / 120)
        let commit = lastTarget + PresentationClock.maxExtrapolationNanos + 1
        let estimate = rig.clock.presented(commitEndNanos: commit, on: rig.scheduler)
        let frame = Self.nanos(1.0 / 120)
        #expect(estimate.basis == .nominal)
        #expect(estimate.nanos == commit + frame / 2 + frame)
    }

    @Test func aPhaseOfAnotherDisplayIsNotExtended() {
        let rig = Rig(minimumRefresh: 1.0 / 120, maximumRefresh: 1.0 / 24)
        rig.typedKey(at: 1000, refresh: 1.0 / 120)
        // The window moves from the ProMotion panel to a 60 Hz external display.
        rig.display = PresentationDisplay(displayID: 2, minimumRefreshInterval: 1.0 / 60, maximumRefreshInterval: 1.0 / 60)
        let commit = Self.nanos(1000.1)
        let estimate = rig.clock.presented(commitEndNanos: commit, on: rig.scheduler)
        let frame = Self.nanos(1.0 / 60)
        #expect(estimate.basis == .nominal)
        #expect(estimate.nanos == commit + frame / 2 + frame)
        #expect(estimate.refreshNanos == frame)
        #expect(!estimate.isVariableRefresh)
        // Moving back does not bring the old phase back either.
        rig.display = PresentationDisplay(displayID: 1, minimumRefreshInterval: 1.0 / 120, maximumRefreshInterval: 1.0 / 24)
        #expect(rig.clock.presented(commitEndNanos: commit, on: rig.scheduler).basis == .nominal)
    }

    @Test func aWindowWithNoTickUsesTheNominalRefreshAndStartsNoLink() {
        let rig = Rig(minimumRefresh: 1.0 / 60)
        let commit = Self.nanos(2000)
        rig.commit(commit)
        let frame = Self.nanos(1.0 / 60)
        #expect(rig.resolved.first?.nanos == commit + frame / 2 + frame)
        #expect(rig.resolved.first?.basis == .nominal)
        #expect(rig.clock.presented(commitEndNanos: commit, on: rig.scheduler) == rig.resolved.first)
        #expect(rig.linksMade == 0)
        #expect(!rig.scheduler.hasLink)
        #expect(rig.scheduler.activeClients.isEmpty)
    }

    @Test func aCommitRidesALinkAnotherClientRunsForOneFrame() {
        let rig = Rig(minimumRefresh: 1.0 / 120)
        let spring = FrameClient(owner: "spring", on: rig.scheduler) { _ in true }
        spring.activate()
        // No input hold: an animation keeps the link running, and the commit takes its next tick.
        rig.commit(Self.nanos(1000) + 2_000_000)
        #expect(rig.resolved.isEmpty)
        rig.frame(at: 1000, refresh: 1.0 / 120)
        let frame = Self.nanos(1.0 / 120)
        #expect(rig.resolved.first?.nanos == Self.nanos(1000 + 1.0 / 120) + frame)
        #expect(rig.resolved.first?.basis == .heldVsync)
        #expect(rig.scheduler.activeClients == ["spring"])
        #expect(rig.linksMade == 1)
        spring.deactivate()
    }

    @Test func aHoldOfStalledFramesOnlyResolvesItsCommitsWithNoVsync() {
        let rig = Rig(minimumRefresh: 1.0 / 60)
        rig.clock.holdForInput(on: rig.scheduler)
        let commit = Self.nanos(2000)
        rig.commit(commit)
        for _ in 0..<(PresentationClock.holdFrames - 1) {
            rig.scheduler.frameDidFire(timestamp: nil, refreshInterval: nil)
            #expect(rig.resolved.isEmpty)
        }
        rig.scheduler.frameDidFire(timestamp: nil, refreshInterval: nil)
        let frame = Self.nanos(1.0 / 60)
        #expect(rig.resolved.first?.basis == .nominal)
        #expect(rig.resolved.first?.nanos == commit + frame / 2 + frame)
        #expect(!rig.scheduler.hasLink)
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
        #expect(rig.clock.presented(commitEndNanos: Self.nanos(2000), on: rig.scheduler).basis == .nominal)
    }

    // MARK: Variable refresh

    @Test func aVariableRefreshDisplayIsLabelled() {
        let rig = Rig(minimumRefresh: 1.0 / 120, maximumRefresh: 1.0 / 48)
        #expect(rig.clock.presented(commitEndNanos: Self.nanos(2000), on: rig.scheduler).isVariableRefresh)
        rig.clock.holdForInput(on: rig.scheduler)
        rig.commit(Self.nanos(1000))
        rig.frame(at: 1000, refresh: 1.0 / 120)
        #expect(rig.resolved.first?.basis == .heldVsync)
        #expect(rig.resolved.first?.isVariableRefresh == true)
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
