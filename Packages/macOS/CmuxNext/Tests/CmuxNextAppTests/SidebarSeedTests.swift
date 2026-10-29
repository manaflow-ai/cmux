@testable import CmuxNextSidebar
import CmuxNextWakeups
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

    /// A seed whose grace is a deadline on `rig`: it ends when the test fires the rig, never on wall-clock time.
    private static func seed(_ rig: MainDeadlineRig) -> SidebarSeed {
        SidebarSeed(grace: SidebarPlaceholderGrace(deadlines: rig.deadlines))
    }

    @Test func connectingMachineGetsBarsOnlyDuringLaunch() {
        let rig = MainDeadlineRig()
        var seed = Self.seed(rig)
        let connecting = [Self.section()]

        #expect(!Self.hasPlaceholders(seed.merge(connecting, launching: true)))
        rig.fireAndRun()
        #expect(Self.hasPlaceholders(seed.merge(connecting, launching: true)))

        // A late connecting snapshot after launch settlement is an empty
        // state, never a second placeholder flash.
        #expect(!Self.hasPlaceholders(seed.merge(connecting, launching: false)))
    }

    @Test func unavailableMachineRemovesBarsAndDoesNotResurrect() {
        let rig = MainDeadlineRig()
        var seed = Self.seed(rig)
        let connecting = [Self.section()]
        _ = seed.merge(connecting, launching: true)
        rig.fireAndRun()
        #expect(Self.hasPlaceholders(seed.merge(connecting, launching: true)))

        // The daemon can still label the header `connecting` while startup
        // reports unavailable; the explicit failed set closes that race.
        #expect(!Self.hasPlaceholders(seed.merge(connecting, launching: true, failed: [Self.machineID])))
        #expect(!Self.hasPlaceholders(seed.merge(connecting, launching: true)))
    }

    @Test func failedStatusAlsoSuppressesLaunchBars() {
        let rig = MainDeadlineRig()
        var seed = Self.seed(rig)
        let connecting = [Self.section()]
        _ = seed.merge(connecting, launching: true)
        rig.fireAndRun()
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
        var seed = SidebarSeed(sections: [saved], grace: SidebarPlaceholderGrace(deadlines: MainDeadlineRig().deadlines))
        let shown = seed.merge([saved], launching: true)
        #expect(seed.isReadyForReveal(shown, launching: true), "the saved sidebar (no workspaces) stayed clear until the launch ended")
    }

    @Test func savedRowsShowAtOnceAndPlaceholdersWait() {
        let local = MachineID("local")
        let machine = SidebarMachine(id: local, name: "This Mac", kind: .local, status: .connected)
        let row = SidebarWorkspace(id: WorkspaceID("w1"), machineID: local, title: "w1", rowState: .stale)
        let saved = SidebarSection(kind: .machine(machine), nodes: [.workspace(row)])
        var seed = SidebarSeed(sections: [saved], grace: SidebarPlaceholderGrace(deadlines: MainDeadlineRig().deadlines))
        let empty = SidebarSection(kind: .machine(machine), nodes: [])
        #expect(seed.isReadyForReveal(seed.merge([empty], launching: true), launching: true), "the saved rows stand in: they show in the first frame")
        let bars = SidebarSection(kind: .machine(machine), nodes: SidebarSeed.placeholders(machine: local).map(SidebarNode.workspace))
        #expect(!seed.isReadyForReveal([bars], launching: true), "placeholder bars alone are not the sidebar's rows")
    }

    /// The grace is a `visible` deadline on the app's placer (R-timer): no bars before its 300 ms, one
    /// rows pass (`onEnd`) when it fires, and a section that stops loading cancels its wake.
    @Test func theGraceIsAVisibleDeadlineThatEndsOnceAndCancelsWithItsSection() {
        let rig = MainDeadlineRig()
        let grace = SidebarPlaceholderGrace(deadlines: rig.deadlines)
        var ends = 0
        grace.onEnd = { ends += 1 }
        var seed = SidebarSeed(grace: grace)
        let connecting = [Self.section()]

        #expect(!Self.hasPlaceholders(seed.merge(connecting, launching: true)))
        #expect(rig.hasArmedWake, "the first ask armed no grace deadline")
        rig.advance(by: .milliseconds(100))
        rig.fireAtNow()
        #expect(ends == 0 && !Self.hasPlaceholders(seed.merge(connecting, launching: true)), "the bars came before the grace")
        rig.fireAndRun()
        #expect(rig.elapsed >= 0.3, "the grace ended \(rig.elapsed) s in")
        #expect(ends == 1, "the grace's end ran \(ends) rows passes")
        #expect(Self.hasPlaceholders(seed.merge(connecting, launching: true)))

        let other = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("cloud-2"), name: "Cloud 2", kind: .cloud, status: .connecting)),
                                   nodes: [])
        _ = seed.merge(connecting + [other], launching: true)
        #expect(rig.hasArmedWake, "a second connecting section armed no grace")
        grace.reset(other.id)
        rig.fireAndRun()
        #expect(ends == 1, "a reset section's grace still ran its end")
    }
}
