import Foundation
@testable import CmuxNextTerminal
import Testing

/// The first terminal surface's cost: its `ghostty_surface_new` and the view's setup are split
/// into runtime phases once per runtime, and the launch prefetch picks the Metal device Ghostty picks.
@MainActor
struct TerminalFirstSurfaceCostTests {
    /// A clock that advances `step` per read, from one fixed instant.
    final class SteppingClock {
        private let start = ContinuousClock.now
        private let step: Duration
        private var reads = 0

        init(step: Duration) { self.step = step }

        func now() -> ContinuousClock.Instant {
            defer { reads += 1 }
            return start + step * reads
        }
    }

    @Test("Only the first surface is split, into its four phases in order, each on the split's clock")
    func onlyTheFirstSurfaceIsSplit() {
        let clock = SteppingClock(step: .milliseconds(3))
        var phases: [(String, Duration)] = []
        var signposts: [String] = []
        let split = TerminalFirstSurfaceSplit(now: clock.now, record: { phases.append(($0, $1)) },
                                              surfaceNewBegan: { signposts.append("begin") },
                                              surfaceNewEnded: { signposts.append("end") })
        var run = split.begin()
        #expect(run != nil)
        #expect(signposts == ["begin"], "the launch interval opens before ghostty_surface_new")
        run?.ended(.surfaceNew)
        #expect(signposts == ["begin", "end"])
        run?.ended(.surfaceSetup)
        run?.ended(.surfaceFit)
        run?.ended(.surfaceState)
        #expect(phases.map(\.0) == ["surface_new", "surface_setup", "surface_fit", "surface_state"])
        #expect(phases.map(\.1) == Array(repeating: .milliseconds(3), count: 4), "one clock read per phase end")
        #expect(signposts == ["begin", "end"], "only surface_new ends the launch interval")
        #expect(split.begin() == nil, "a later surface pays no font discovery: no split")
        #expect(signposts.count == 2)
    }

    @Test("The start phases keep their ring codes; the first surface's follow them")
    func phaseCodesAreStable() {
        let codes = ["ghostty_init", "config_load", "app_new", "surface_new", "surface_setup", "surface_fit", "surface_state"]
            .map(TerminalTimings.RuntimePhase.traceCode(of:))
        #expect(codes == [1, 2, 3, 4, 5, 6, 7])
        #expect(TerminalTimings.RuntimePhase.traceCode(of: "unknown") == 0)
    }
}
