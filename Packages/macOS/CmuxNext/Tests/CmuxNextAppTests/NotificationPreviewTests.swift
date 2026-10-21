@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// A finished turn's banner shows what the agent said (cx-kz6m0; Leo 2026-10-14: on by default).
/// The daemon carries the agent's last message beside the notification as `preview`, memory
/// only; the app makes it the banner's body. `cmux notify --subtitle` reaches the banner too.
@MainActor
struct NotificationPreviewTests {
    /// The banner the app posts for a daemon notification `wire` from an agent on a terminal tab.
    func banner(_ wire: String, configure: (NotificationCenterService) -> Void = { _ in }) throws -> DesktopNotifier.Posted? {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "api-server", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let located = LocatedTab(tab: try #require(paneModel.tabs.first), pane: paneModel, workspace: workspace)
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        let service = NotificationCenterService()
        // A test host's screen may read as locked: unlocked unless a case says otherwise.
        service.screenLocked = { false }
        configure(service)
        var decision = NotificationPolicy.Decision()
        decision.desktop = true
        let source = NotificationSource(rawValue: notification.source ?? "") ?? .agent
        service.deliver(notification, source: source, located: located, decision: decision, program: nil)
        return service.desktop.posted.last
    }

    static let finished = #"{"notification":5,"title":"Claude finished","body":"","preview":"Fixed the flaky login test and pushed the branch.","level":"info","surface":1,"source":"agent"}"#

    @Test func aFinishedTurnsBannerSaysWhatTheAgentSaid() throws {
        let posted = try #require(try banner(Self.finished))
        #expect(posted.title == "api-server", "the banner says where: the workspace (the tab has no name)")
        #expect(posted.subtitle == "Claude finished")
        #expect(posted.body == "Fixed the flaky login test and pushed the branch.")
    }

    @Test func showPreviewsKeepsTheMessageOffTheLockScreenOrEverywhere() throws {
        func body(_ previews: NotificationPreviews, locked: Bool) throws -> String? {
            try banner(Self.finished) { service in
                service.previews = previews
                service.screenLocked = { locked }
            }?.body
        }
        let message = "Fixed the flaky login test and pushed the branch."
        #expect(try body(.whenUnlocked, locked: false) == message)
        #expect(try body(.whenUnlocked, locked: true) == "", "the default hides it while the screen is locked")
        #expect(try body(.always, locked: true) == message)
        #expect(try body(.never, locked: false) == "")
        #expect(NotificationCenterService().previews == .whenUnlocked, "previews are on by default")
    }

    @Test func aNotifySubtitleReachesTheBanner() throws {
        let wire = #"{"notification":6,"title":"Deploy","subtitle":"staging","body":"done","level":"info","surface":1,"source":"cli"}"#
        let posted = try #require(try banner(wire))
        #expect(posted.subtitle == "Deploy · staging")
        #expect(posted.body == "done")
    }
}
