import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-04: "i feel like the restarted after nightly update does too many layout shifts/flicker
/// renderings". The relaunch bench showed the footer's account item draw its 18 pt glyph in the first frame
/// and the 24 pt avatar a turn later, in about every window: the avatar came from a task's first loop pass.
@MainActor struct SidebarProfileControlFirstFrameTests {
    @Test func installGivesTheAvatarBeforeTheFirstFrame() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let model = SidebarModel()
        let sidebar = SidebarView(model: model, design: DesignSettings())
        SidebarProfileControl(services: services, state: nil).install(model: model, sidebar: sidebar)
        #expect(model.profileAvatar != nil, "the account item draws the avatar in the turn the window is made")
    }

    /// The window's init runs before its sidebar's selection pass, so the sidebar has no active workspace yet:
    /// the first avatar is the shown workspace's own profile, never the room default it would switch from.
    @Test func theFirstAvatarIsTheShownWorkspacesProfile() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1",
                              screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, kind: .pty, title: "zsh", url: "")])])]),
        ]))
        let workspace = try #require(services.machines.local.store.workspaces.first?.id)
        let profile = try await services.browserProfiles.createProfile(name: "Work", color: nil, icon: nil)
        try services.browserProfiles.setWorkspaceDefault(profile, for: workspace)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        state.workspaceID = workspace
        let model = SidebarModel()
        #expect(model.activeWorkspaceID == nil, "no selection pass has run")
        SidebarProfileControl(services: services, state: state).install(model: model, sidebar: SidebarView(model: model, design: DesignSettings()))
        #expect(model.profileAvatar?.name == "Work", "the first frame draws the shown workspace's profile")
    }
}
