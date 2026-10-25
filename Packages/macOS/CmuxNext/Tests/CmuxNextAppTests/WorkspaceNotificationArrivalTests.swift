import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// `cmux notify --workspace ws_…`: the daemon's event names the workspace and no terminal. Its
/// banner names that workspace, and a muted workspace posts none, as for a terminal's notification.
@MainActor
struct WorkspaceNotificationArrivalTests {
    static func arrive(muted: Bool) throws -> (NotificationCenterService, WorkspaceModel) {
        _ = NSApplication.shared
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, resourceID: "ws_00000000000000000000000000000042", name: "build", screens: [screen]),
        ]))
        let wire = #"{"notification":9,"title":"Deploy done","body":"","level":"info","workspace_id":"ws_00000000000000000000000000000042","source":"cli"}"#
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        #expect(notification.workspaceID?.rawValue == "ws_00000000000000000000000000000042")
        let workspace = try #require(NotificationCenterService.workspace(of: notification, in: store))
        let service = NotificationCenterService()
        service.terminalNotificationsEnabled = { true }
        if muted { service.preferences.mutedWorkspaces = [workspace.id] }
        service.arrive(notification, located: nil, workspace: workspace)
        return (service, workspace)
    }

    @Test func aWorkspaceNotificationsBannerNamesItsWorkspace() throws {
        let (service, _) = try Self.arrive(muted: false)
        let banner = try #require(service.desktop.posted.last)
        // Where in the title, what in the subtitle (NotificationBannerFormatter).
        #expect(banner.title == "build", "the banner did not name its workspace")
        #expect(banner.subtitle == "Deploy done")
    }

    @Test func aMutedWorkspacePostsNoBanner() throws {
        let (service, _) = try Self.arrive(muted: true)
        #expect(service.desktop.posted.isEmpty, "a muted workspace's notification posted a banner")
    }
}
