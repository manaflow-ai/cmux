import Foundation
import Testing
@testable import CmuxTerminal

/// (C) ExternalHover diagnostics — review B5's shared dropped-count
/// baseline. `ExternalHoverWorkService`'s own drains and
/// `TerminalSurfaceRuntimeTeardownCoordinator`'s final teardown drain
/// both report into the SAME `ExternalHoverDroppedCountTracker` instance
/// (see `ExternalHoverWorkService.init`'s doc) — these tests exercise the
/// tracker directly, which is what makes "a normal drain already
/// reported N ⇒ a later report of the same cumulative N is a zero delta"
/// and "two surfaces sharing an event never cross-contaminate" true
/// regardless of WHICH side (actor drain, or teardown's `nonisolated`
/// drain) makes the call.
@Suite struct ExternalHoverDroppedCountTrackerTests {
    private static func makeLifetime(_ generation: UInt64 = 1) -> RuntimeSurfaceLifetimeID {
        .init(surfaceID: UUID(), runtimeSurfaceGeneration: generation)
    }

    @Test("The first report for a lifetime is its own delta, since there is no prior baseline")
    func firstReportIsItsOwnDelta() {
        let tracker = ExternalHoverDroppedCountTracker()
        let lifetimeID = Self.makeLifetime()

        let delta = tracker.reportAndComputeDelta(lifetimeID: lifetimeID, cumulative: 5)

        #expect(delta == 5)
        #expect(tracker.previousByLifetime[lifetimeID] == 5)
    }

    /// This is the exact review B5 scenario: whichever side (the actor's
    /// own drain, or the teardown coordinator's final drain) reports N
    /// FIRST, the other side reporting the SAME cumulative N later must
    /// see a zero delta — never re-report drops the first side already
    /// reported.
    @Test("A later report of the SAME cumulative value computes a zero delta, regardless of which side reported first")
    func laterReportOfTheSameCumulativeValueIsAZeroDelta() {
        let tracker = ExternalHoverDroppedCountTracker()
        let lifetimeID = Self.makeLifetime()

        let firstDelta = tracker.reportAndComputeDelta(lifetimeID: lifetimeID, cumulative: 7)
        #expect(firstDelta == 7, "the actor's own drain reports the first batch of drops")

        // Simulates the teardown coordinator's final drain observing the
        // SAME ring cumulative value the actor's drain already reported —
        // e.g. no new drops happened between the last setter/render-
        // trigger drain and teardown.
        let teardownDelta = tracker.reportAndComputeDelta(lifetimeID: lifetimeID, cumulative: 7)
        #expect(teardownDelta == 0, "teardown's report of the same cumulative value the actor already reported must never be re-reported as a delta")
    }

    @Test("A genuinely new drop batch since the last report computes a nonzero delta")
    func aGenuinelyNewDropBatchComputesANonzeroDelta() {
        let tracker = ExternalHoverDroppedCountTracker()
        let lifetimeID = Self.makeLifetime()

        _ = tracker.reportAndComputeDelta(lifetimeID: lifetimeID, cumulative: 3)
        let delta = tracker.reportAndComputeDelta(lifetimeID: lifetimeID, cumulative: 10)

        #expect(delta == 7, "only the NEW drops since the last report, never the full cumulative value again")
    }

    /// Review B5: two surfaces (distinct `RuntimeSurfaceLifetimeID`s, even
    /// if their underlying Ghostty `event` counters happen to collide,
    /// per design v4 §1) must never share or cross-contaminate each
    /// other's dropped-count baseline through this ONE shared tracker.
    @Test("Two surfaces track their dropped-count baselines independently through the shared tracker")
    func twoSurfacesTrackIndependentlyThroughTheSharedTracker() {
        let tracker = ExternalHoverDroppedCountTracker()
        let lifetimeA = Self.makeLifetime()
        let lifetimeB = Self.makeLifetime()

        // Surface A's normal drain reports first.
        _ = tracker.reportAndComputeDelta(lifetimeID: lifetimeA, cumulative: 4)
        // Surface B tears down with a much larger cumulative value — must
        // be treated as its OWN fresh baseline, not offset by A's.
        let teardownDeltaB = tracker.reportAndComputeDelta(lifetimeID: lifetimeB, cumulative: 20)
        #expect(teardownDeltaB == 20, "surface B's first report must be its own full cumulative value, unaffected by surface A's baseline")

        // Surface A tears down next — its own baseline (4) must still be
        // exactly what it was, not clobbered by B's report.
        let teardownDeltaA = tracker.reportAndComputeDelta(lifetimeID: lifetimeA, cumulative: 4)
        #expect(teardownDeltaA == 0, "surface A's teardown report of its own unchanged cumulative value must be a zero delta")
    }

    @Test("closeLifetime removes a lifetime's baseline so a later reused lifetime ID (if it ever recurred) starts fresh")
    func closeLifetimeRemovesTheBaseline() {
        let tracker = ExternalHoverDroppedCountTracker()
        let lifetimeID = Self.makeLifetime()

        _ = tracker.reportAndComputeDelta(lifetimeID: lifetimeID, cumulative: 6)
        #expect(tracker.previousByLifetime[lifetimeID] == 6)

        tracker.closeLifetime(lifetimeID)

        #expect(tracker.previousByLifetime[lifetimeID] == nil)
    }
}
