import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSidebar
import Testing

/// Every way to pick a workspace by sidebar position (Cmd+1…9, next/prev
/// sidebar tab, select first/last, a select intent) skips placeholder rows,
/// so a `placeholder:` id never becomes a window member or the shown
/// workspace. The window is a registered one, so a claim would really move.
@MainActor @Suite struct SidebarPlaceholderActionTests {
    typealias Fixture = SidebarSnapshotFirstTests

    /// A restored window listing three live workspaces, with a connecting
    /// Cloud section of placeholders below them.
    static func window() async throws -> (AppServices, WindowController) {
        let services = Fixture.services(file: nil)
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        services.daemon.store.apply(snapshot: Fixture.tree([1, 2, 3]))
        await Fixture.settle {
            !services.windows.registry.isLaunching && Fixture.rows(controller).filter { $0.rowState == .live }.count == 3
        }
        try #require(services.windows.registry.value.window(controller.state.id)?.isOpen == true)
        return (services, controller)
    }

    static func addPlaceholders(_ controller: WindowController) {
        let cloud = MachineID("cloud-1")
        let section = SidebarSection(kind: .machine(SidebarMachine(id: cloud, name: "Cloud", kind: .cloud, status: .connecting)),
                                     nodes: SidebarSeed.placeholders(machine: cloud).map(SidebarNode.workspace))
        let model = controller.sidebar.model
        model.sections = model.sections.filter { $0.machine?.id != cloud } + [section]
    }

    static func expectNoPlaceholder(_ services: AppServices, _ controller: WindowController, _ step: String) {
        let members = services.windows.registry.members(of: controller.state.id)
        #expect(!members.contains { $0.hasPrefix("placeholder:") }, "\(step): a placeholder became a member")
        #expect(!(controller.state.workspaceID ?? "").hasPrefix("placeholder:"), "\(step): a placeholder is shown")
    }

    @Test func selectWorkspaceByNumberSkipsPlaceholders() async throws {
        let (services, controller) = try await Self.window()
        Self.addPlaceholders(controller)
        services.registry.perform("selectWorkspaceByNumber", invocation: ActionInvocation(arguments: ["index": .int(9)]))
        Self.expectNoPlaceholder(services, controller, "Cmd+9")
        #expect(controller.state.workspaceID == Fixture.id(3))
        Fixture.closeAll(services)
    }

    @Test func nextAndPreviousSidebarTabSkipPlaceholders() async throws {
        let (services, controller) = try await Self.window()
        services.windows.show(workspaceID: Fixture.id(3), in: controller.state)
        Self.addPlaceholders(controller)
        // The walk covers every item (SIDEBAR-NUMBERING-AND-STEPPING): past the
        // last row it wraps to the first top item (Home), never a placeholder.
        services.registry.perform("nextSidebarTab", invocation: ActionInvocation())
        Self.expectNoPlaceholder(services, controller, "next sidebar tab")
        #expect(controller.state.page == .home || controller.state.workspaceID == Fixture.id(1))
        Self.addPlaceholders(controller)
        services.registry.perform("prevSidebarTab", invocation: ActionInvocation())
        Self.expectNoPlaceholder(services, controller, "previous sidebar tab")
        #expect(controller.state.page == nil && controller.state.workspaceID == Fixture.id(3))
        Fixture.closeAll(services)
    }

    @Test func selectLastSkipsPlaceholders() async throws {
        let (services, controller) = try await Self.window()
        Self.addPlaceholders(controller)
        services.registry.perform("workspace.selectLast", invocation: ActionInvocation())
        Self.expectNoPlaceholder(services, controller, "select last")
        #expect(controller.state.workspaceID == Fixture.id(3))
        Fixture.closeAll(services)
    }

    @Test func aPlaceholderSelectIntentNeverReachesTheWindow() async throws {
        let (services, controller) = try await Self.window()
        Self.addPlaceholders(controller)
        let placeholder = try #require(controller.sidebar.model.allWorkspaces.first { $0.rowState == .placeholder })
        controller.sidebar.model.onIntent?(.select(placeholder.id))
        Self.expectNoPlaceholder(services, controller, "select intent")
        Fixture.closeAll(services)
    }
}
