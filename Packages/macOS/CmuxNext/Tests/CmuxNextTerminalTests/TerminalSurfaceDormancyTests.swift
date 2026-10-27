@testable import CmuxNextTerminal
import Testing

/// When a hidden terminal's surface goes and comes back (p01-process-140, ``TerminalSurfaceDormancy``): only
/// after the whole grace hidden, only with an owner that can rebuild it and no state only the surface holds,
/// and a released surface stays released until shown, whatever its stream does meanwhile.
@Suite struct TerminalSurfaceDormancyTests {
    private static let hidden = TerminalSurfaceDormancy.Inputs(hidden: true, rebuildable: true, pinned: false)
    private static let shown = TerminalSurfaceDormancy.Inputs(hidden: false, rebuildable: true, pinned: false)

    @Test func releasesOnlyAfterTheGraceAndRebuildsWhenShown() {
        var dormancy = TerminalSurfaceDormancy()
        #expect(dormancy.update(Self.shown) == .none)
        #expect(dormancy.update(Self.hidden) == .startGrace)
        #expect(dormancy.update(Self.hidden) == .none, "a repeated hide restarted the grace")
        #expect(dormancy.graceEnded(Self.hidden) == .release)
        #expect(dormancy.state == .released)
        #expect(dormancy.update(Self.shown) == .rebuild)
        #expect(dormancy.state == .live)
        #expect(dormancy.graceEnded(Self.hidden) == .none, "a stale grace released a live surface")
    }

    @Test func showingDuringTheGraceKeepsTheSurface() {
        var dormancy = TerminalSurfaceDormancy()
        #expect(dormancy.update(Self.hidden) == .startGrace)
        #expect(dormancy.update(Self.shown) == .cancelGrace)
        #expect(dormancy.graceEnded(Self.hidden) == .none, "the cancelled grace still released")
        #expect(dormancy.state == .live)
    }

    @Test func aSurfaceNothingCanRebuildIsKept() {
        var bare = TerminalSurfaceDormancy()
        #expect(bare.update(TerminalSurfaceDormancy.Inputs(hidden: true, rebuildable: false, pinned: false)) == .none)
        var pinned = TerminalSurfaceDormancy()
        #expect(pinned.update(TerminalSurfaceDormancy.Inputs(hidden: true, rebuildable: true, pinned: true)) == .none)

        var dropped = TerminalSurfaceDormancy()
        #expect(dropped.update(Self.hidden) == .startGrace)
        let disconnected = TerminalSurfaceDormancy.Inputs(hidden: true, rebuildable: false, pinned: false)
        #expect(dropped.graceEnded(disconnected) == .none, "the grace released a surface whose stream dropped")
        #expect(dropped.state == .live)
    }

    @Test func aReleasedSurfaceStaysReleasedWhileHidden() {
        var dormancy = TerminalSurfaceDormancy()
        _ = dormancy.update(Self.hidden)
        _ = dormancy.graceEnded(Self.hidden)
        #expect(dormancy.update(TerminalSurfaceDormancy.Inputs(hidden: true, rebuildable: false, pinned: false)) == .none)
        #expect(dormancy.state == .released, "a dropped stream rebuilt a hidden surface")
        #expect(dormancy.update(TerminalSurfaceDormancy.Inputs(hidden: false, rebuildable: false, pinned: false)) == .rebuild)
    }
}
