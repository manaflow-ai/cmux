import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// cx-8g25: a click on a sidebar section header (This Mac, Pinned, a
/// machine) toasted "needs daemon capability profiles-v1" and did not
/// collapse, because the bridge sent every organization intent it did not
/// map to a capability refusal. A section's collapse is the window's own
/// view state: it needs no daemon, survives the live remap and a relaunch
/// (the window's sidebar snapshot file). An organization intent sent before
/// the home session's personal state loads waits for it.
@MainActor @Suite struct SidebarSectionCollapseTests {
    typealias Fixture = SidebarSnapshotFirstTests
    static let local = SectionID.machine(.local)

    static func section(_ controller: WindowController) -> CmuxNextSidebar.SidebarSection? {
        controller.sidebar.model.sections.first { $0.id == local }
    }

    static func observeNotices(_ services: AppServices) -> NoticeLog {
        let log = NoticeLog()
        services.registry.refusalObserver = { reason, _ in log.notices.append(reason) }
        return log
    }

    @Test func aSectionHeaderClickCollapsesWithoutANoticeAndSurvivesRelaunch() async throws {
        let file = Fixture.tempFile()
        let services = Fixture.services(file: file)
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        services.daemon.store.apply(snapshot: Fixture.tree([1, 2, 3]))
        await Fixture.settle { !services.windows.registry.isLaunching && Self.section(controller) != nil }
        let log = Self.observeNotices(services)

        controller.sidebar.model.send(.toggleCollapse(.section(Self.local)))
        #expect(log.notices.isEmpty, "\(log.notices)")
        #expect(Self.section(controller)?.isCollapsed == true)

        // The next live change remaps the daemon's rows: still collapsed.
        services.daemon.store.apply(snapshot: Fixture.tree([1, 2]))
        await Fixture.settle { Fixture.rows(controller).count == 2 }
        #expect(Fixture.rows(controller).count == 2)
        #expect(Self.section(controller)?.isCollapsed == true)

        // Relaunch: a new app reads the same sidebar snapshot file.
        for _ in 0..<200 { await Task.yield() }
        await services.sidebarSnapshots.flush()
        Fixture.closeAll(services)
        let relaunched = Fixture.services(file: SidebarSnapshotFile(url: file.url))
        relaunched.windows.restoreWhenLoaded()
        let next = try #require(relaunched.windows.controllers.first)
        #expect(Self.section(next)?.isCollapsed == true)
        relaunched.daemon.store.apply(snapshot: Fixture.tree([1, 2]))
        await Fixture.settle { Fixture.rows(next).allSatisfy { $0.rowState == .live } && !Fixture.rows(next).isEmpty }
        #expect(Self.section(next)?.isCollapsed == true)

        // Expanding again is the same local toggle.
        next.sidebar.model.send(.toggleCollapse(.section(Self.local)))
        #expect(Self.section(next)?.isCollapsed == false)
        Fixture.closeAll(relaunched)
    }

    /// Before the local daemon answers, a group intent waits: no notice.
    @Test func anOrganizationIntentBeforePersonalStateWaitsWithoutANotice() throws {
        let services = Fixture.services(file: nil)
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        let log = Self.observeNotices(services)
        controller.sidebar.model.send(.createGroup(GroupID("grp_new"), name: "Work", color: .green, workspaces: []))
        controller.sidebar.model.send(.toggleCollapse(.group(GroupID("grp_new"))))
        #expect(log.notices.isEmpty, "\(log.notices)")
        Fixture.closeAll(services)
    }

    /// A connected daemon without `profiles-v1` (an older build) refuses a
    /// group intent with a reason that names no capability id.
    @Test func anOlderDaemonRefusesGroupsWithAHumanReason() async throws {
        let services = Fixture.services(file: nil)
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        services.daemon.store.noteHandshake(DaemonIdentity(capabilities: DaemonCapabilities.shared.required, generation: "g1"))
        services.daemon.store.apply(snapshot: Fixture.tree([1]))
        await Fixture.settle { !Fixture.rows(controller).isEmpty }
        let log = Self.observeNotices(services)
        controller.sidebar.model.send(.createGroup(GroupID("grp_new"), name: "Work", color: .green, workspaces: []))
        #expect(log.notices.count == 1)
        #expect(!log.notices.contains(where: CapabilityRefusalTests.namesCapability), "\(log.notices)")
        Fixture.closeAll(services)
    }
}

@MainActor final class NoticeLog {
    var notices: [String] = []
}
