import CmuxNextActions
import CmuxNextSettings
import Testing
@testable import CmuxNextApp

/// Leo (2026-10-09): the sidebar's menus have Show Tabs Under Workspaces, a
/// checkmark toggle of `sidebar.showWorkspaceTabs` (the Settings row Show
/// Workspace Tabs), which lists each workspace's tabs beneath it.
@MainActor @Suite struct SidebarWorkspaceTabsToggleTests {
    @Test func theToggleFlipsTheWorkspaceTabsSetting() {
        #expect(SidebarWorkspaceTabsToggle.path == SidebarSectionsSetting.showWorkspaceTabsPath)
        #expect(SidebarWorkspaceTabsToggle.next(showing: false) == true)
        #expect(SidebarWorkspaceTabsToggle.next(showing: true) == false)
    }

    @Test func theMenuChecksTheToggleFromTheSetting() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let state = services.registry.action(for: SidebarWorkspaceTabsToggle.id)?.targetState
        // Off by default: no settings file lists the tabs.
        #expect(state?(ActionInvocation()) == false)
    }
}
