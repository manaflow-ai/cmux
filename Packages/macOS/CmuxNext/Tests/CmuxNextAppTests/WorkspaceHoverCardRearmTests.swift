import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The shown workspace card re-arms its one deadline whenever its content changes
/// (p14-energy-057): a command that starts while the card shows a day-old status reads "· 1s",
/// so the next deadline is about a second away, not the old content's next hour boundary.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardRearmTests {
    private static let id = WorkspaceID("ws-rearm")

    @Test func aContentChangeReArmsTheDeadlineForTheNewSoonestChange() async throws {
        _ = NSApplication.shared
        let clock = ManualClock()
        let controller = WorkspaceHoverCardController(
            coordinator: HoverCardCoordinator(clock: ManualClock()),
            ticker: DemandTimer(owner: "test.hover-card.elapsed", clock: clock, ledger: WakeupLedger()))
        var workspace = SidebarWorkspace(id: Self.id, title: "api", activity: .working)
        // Working for 1d 4h 2m: the text next changes at the next hour boundary, about 58 min away.
        workspace.detail = SidebarWorkspaceDetail(activitySince: Date().addingTimeInterval(-(86_400 + 4 * 3600 + 120)))
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let list = SidebarListView(model: SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(workspace)])],
                                                       activeWorkspaceID: nil))
        list.workspaces[Self.id] = workspace
        controller.list = list
        let target = WorkspaceHoverCardController.targetID(Self.id)
        defer { controller.hoverCardDeactivated(target) }

        _ = try #require(controller.hoverCardBody(for: target))
        try await clock.waitForSleeper()
        let first = try #require(clock.sleepRequests.last).deadline.offset
        #expect(first > .seconds(3000) && first <= .seconds(3600), "a day-old status armed \(first), not its next hour boundary")

        // A command starts now: the card reconfigures (as `HoverCardCoordinator.contentChanged` asks it to).
        list.workspaces[Self.id]?.detail.command = "make test"
        list.workspaces[Self.id]?.detail.commandSince = Date()
        _ = try #require(controller.hoverCardBody(for: target))
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.count == 2, "the content change kept the old content's deadline")
        let second = try #require(clock.sleepRequests.last).deadline.offset
        #expect(second <= .seconds(2), "the new command's running time armed \(second), not its next second")
        #expect(clock.sleeperCount == 1, "the old deadline still sleeps beside the new one")
    }
}
