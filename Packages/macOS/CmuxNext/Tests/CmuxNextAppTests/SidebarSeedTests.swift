@testable import CmuxNextSidebar
import Testing

/// Regression coverage for the launch-only Cloud rows in ``SidebarSeed``.
///
/// The sidebar may receive a stale `connecting` snapshot after the launch
/// window has already settled. Those rows must not keep the launch bars alive,
/// and a failed first connection must not re-arm them on a later callback.
@MainActor
struct SidebarSeedTests {
    private static let machineID = MachineID("cloud-test")

    private static func section(status: SidebarMachine.Status = .connecting) -> SidebarSection {
        SidebarSection(kind: .machine(SidebarMachine(id: machineID, name: "Cloud test", kind: .cloud, status: status)), nodes: [])
    }

    private static func hasPlaceholders(_ sections: [SidebarSection]) -> Bool {
        sections.flatMap(\.workspaces).contains { $0.rowState == .placeholder }
    }

    /// Lets the injected zero-delay grace timer finish without making the test
    /// wait on wall-clock time.
    private static func drainGrace() async {
        for _ in 0..<4 { await Task.yield() }
    }

    @Test func connectingMachineGetsBarsOnlyDuringLaunch() async {
        let grace = SidebarPlaceholderGrace(clock: ImmediateClock())
        var seed = SidebarSeed(grace: grace)
        let connecting = [Self.section()]

        #expect(!Self.hasPlaceholders(seed.merge(connecting, launching: true)))
        await Self.drainGrace()
        #expect(Self.hasPlaceholders(seed.merge(connecting, launching: true)))

        // A late connecting snapshot after launch settlement is an empty
        // state, never a second placeholder flash.
        #expect(!Self.hasPlaceholders(seed.merge(connecting, launching: false)))
    }

    @Test func unavailableMachineRemovesBarsAndDoesNotResurrect() async {
        let grace = SidebarPlaceholderGrace(clock: ImmediateClock())
        var seed = SidebarSeed(grace: grace)
        let connecting = [Self.section()]
        _ = seed.merge(connecting, launching: true)
        await Self.drainGrace()
        #expect(Self.hasPlaceholders(seed.merge(connecting, launching: true)))

        // The daemon can still label the header `connecting` while startup
        // reports unavailable; the explicit failed set closes that race.
        #expect(!Self.hasPlaceholders(seed.merge(connecting, launching: true, failed: [Self.machineID])))
        #expect(!Self.hasPlaceholders(seed.merge(connecting, launching: true)))
    }

    @Test func failedStatusAlsoSuppressesLaunchBars() async {
        let grace = SidebarPlaceholderGrace(clock: ImmediateClock())
        var seed = SidebarSeed(grace: grace)
        let connecting = [Self.section()]
        _ = seed.merge(connecting, launching: true)
        await Self.drainGrace()
        #expect(Self.hasPlaceholders(seed.merge(connecting, launching: true)))

        let failed = [Self.section(status: .failed)]
        #expect(!Self.hasPlaceholders(seed.merge(failed, launching: true)))
        #expect(!Self.hasPlaceholders(seed.merge(connecting, launching: true)))
    }

    /// A restore launch's sidebar was held clear from its first frame (1830 ms after process
    /// start) to 2744 ms, although its saved sidebar was on screen: that profile had no
    /// workspaces, so no row could ever turn real before the launch ended (Leo's never-blank
    /// first launch frame). A saved sidebar with no rows has nothing to wait for.
    @Test func aSavedSidebarWithNoRowsShowsInTheFirstFrame() {
        let local = MachineID("local")
        let saved = SidebarSection(kind: .machine(SidebarMachine(id: local, name: "This Mac", kind: .local, status: .connected)), nodes: [])
        var seed = SidebarSeed(sections: [saved])
        let shown = seed.merge([saved], launching: true)
        #expect(seed.isReadyForReveal(shown, launching: true), "the saved sidebar (no workspaces) stayed clear until the launch ended")
    }

    @Test func savedRowsShowAtOnceAndPlaceholdersWait() {
        let local = MachineID("local")
        let machine = SidebarMachine(id: local, name: "This Mac", kind: .local, status: .connected)
        let row = SidebarWorkspace(id: WorkspaceID("w1"), machineID: local, title: "w1", rowState: .stale)
        let saved = SidebarSection(kind: .machine(machine), nodes: [.workspace(row)])
        var seed = SidebarSeed(sections: [saved])
        let empty = SidebarSection(kind: .machine(machine), nodes: [])
        #expect(seed.isReadyForReveal(seed.merge([empty], launching: true), launching: true), "the saved rows stand in: they show in the first frame")
        let bars = SidebarSection(kind: .machine(machine), nodes: SidebarSeed.placeholders(machine: local).map(SidebarNode.workspace))
        #expect(!seed.isReadyForReveal([bars], launching: true), "placeholder bars alone are not the sidebar's rows")
    }
}

/// A clock whose sleeps complete on the next task turn.
private struct ImmediateClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until _: Instant, tolerance _: Duration?) async throws {}
}
