import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// Home's close rules (S15, cx-qno.3): the store's home workspace never
/// closes, and the app refuses first with a localized reason. A Close
/// Workspace that names no workspace while a top page shows is refused:
/// before, it closed the workspace parked behind the page.
@MainActor
struct HomeRulesTests {
    /// The reason `closeWorkspace` gives for `invocation`'s target.
    private func closeReason(_ services: AppServices, _ invocation: ActionInvocation) -> String? {
        services.registry.action(for: "closeWorkspace")?.targetUnavailableReason?(invocation)
    }

    @Test func closeWorkspaceOnAPageIsRefusedAndKeepsTheParkedWorkspace() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        let parked = try #require(state.workspaceID)
        TopPages.show(TopPageTests.route, services: services, in: state)
        #expect(window.shownTopPage == TopPageTests.route)

        #expect(closeReason(services, ActionInvocation()) == RefusalStrings.topPageIsNotAWorkspace,
                "Cmd-Shift-W on a page must not close the parked workspace")
        #expect(!services.registry.perform("closeWorkspace", invocation: ActionInvocation()))
        #expect(services.workspace(id: parked) != nil)
        // A row's own Close names its workspace and still runs.
        let named = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: parked))
        #expect(closeReason(services, named) == nil)

        services.windows.select(parked, in: state)
        await BrowserTabTests.settle { window.content != nil }
        #expect(closeReason(services, ActionInvocation()) == nil, "off the page, Close Workspace runs again")
        window.teardown()
        withExtendedLifetime((services, state)) {}
    }

    @Test func theHomeWorkspaceIsNotClosable() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try TopPageTests.homeTree())
        let home = try #require(services.daemon.store.workspaces.first { $0.kind == "home" })
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: home.id))
        #expect(closeReason(services, invocation) == RefusalStrings.homeNotClosable)
        #expect(!services.registry.perform("closeWorkspace", invocation: invocation))
    }

    /// The home row (shown when Home is not in the top rows) offers no close button.
    @Test func theHomeRowHasNoCloseButton() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try TopPageTests.homeTree())
        let home = try #require(services.daemon.store.workspaces.first { $0.kind == "home" })
        #expect(!SidebarMapping.shared.row(home, machine: .local).isClosable)

        let other = AppServices(environment: AppEnvironment.current([:]))
        other.daemon.store.apply(snapshot: try ProviderTabOpenTests.tree(surfaces: [5]))
        let plain = try #require(other.daemon.store.workspaces.first)
        #expect(SidebarMapping.shared.row(plain, machine: .local).isClosable)
    }
}
