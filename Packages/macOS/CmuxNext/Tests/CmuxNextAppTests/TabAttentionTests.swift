import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextRemote
import CmuxNextSidebar
@testable import CmuxNextDaemon
import Foundation
import Testing

/// tab-attention-v1: an agent marks the tab where the person must act. The tab, its workspace
/// row and its pane show the existing unread treatment (the blue dot and ring, no new dot); the
/// row says why; going into the pane hides the ring but keeps the dot; a new request rings again.
@MainActor
@Suite struct TabAttentionTests {
    private static func attention(_ reason: String, at: UInt64) -> TabAttention {
        TabAttention(reason: reason, atMs: at)
    }

    private static func marked() throws -> (NotificationCenterService, WorkspaceModel, TabModel) {
        _ = NSApplication.shared
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "GitHub")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "coord-deputy", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        tab.applyState(SessionStateMirror.TabRecord(attention: attention("Confirm GitHub access", at: 1_000)), progress: nil)
        return (NotificationCenterService(), workspace, tab)
    }

    @Test func theRecordsAttentionParsesAndAMalformedOneIsIgnored() {
        let value = JSONValue.object(["reason": .string("Confirm GitHub access"), "at_ms": .number(1_729_000_000_000)])
        #expect(TabAttention(value) == Self.attention("Confirm GitHub access", at: 1_729_000_000_000))
        #expect(TabAttention(.object(["reason": .string("")])) == nil, "an empty reason is no mark")
        #expect(TabAttention(.string("x")) == nil)
        #expect(TabAttention(nil) == nil)
    }

    @Test func aMarkedTabShowsUnreadUntilTheRecordDropsIt() throws {
        let (_, _, tab) = try Self.marked()
        #expect(tab.showsUnread, "the tab's dot and the screen bar read showsUnread")
        #expect(!tab.markedUnread && !tab.hasUnread, "the mark is not Mark as Unread or a notification")
        tab.applyState(SessionStateMirror.TabRecord(), progress: nil)
        #expect(tab.attention == nil)
        #expect(!tab.showsUnread)
    }

    @Test func theWorkspaceRowShowsTheDotAndTheReason() throws {
        let (_, workspace, _) = try Self.marked()
        let row = SidebarMapping.shared.row(workspace, machine: CmuxNextSidebar.MachineID.local)
        #expect(row.unread == .dot, "the row has no dot for a tab that needs the person")
        #expect(row.notificationText == "Confirm GitHub access")
        #expect(row.tabs.first?.isUnread == true)
        let hidden = SidebarMapping.shared.row(workspace, machine: CmuxNextSidebar.MachineID.local, showsUnread: false)
        #expect(hidden.unread == UnreadState.none, "showOnSidebar off hides it like any unread")
    }

    @Test func thePaneRingsUntilThePersonGoesInAndANewRequestRingsAgain() throws {
        let (service, workspace, tab) = try Self.marked()
        #expect(service.attentionMarks(for: workspace).count == 1, "the marked tab's pane has no ring")
        service.interacted(.focus, tab: tab)
        #expect(service.attentionMarks(for: workspace).count == 1, "focus alone hid the ring")
        service.interacted(.click, tab: tab)
        #expect(service.attentionMarks(for: workspace).isEmpty, "going into the pane left the ring")
        #expect(tab.showsUnread, "going in keeps the mark: only the agent, a navigation or a close clears it")
        tab.applyState(SessionStateMirror.TabRecord(attention: Self.attention("Approve the deploy", at: 2_000)), progress: nil)
        #expect(service.attentionMarks(for: workspace).count == 1, "a new request did not ring again")
        service.dismissHighlight(workspace)
        #expect(service.attentionMarks(for: workspace).isEmpty, "Dismiss Highlight left the ring")
    }

    @Test func goingIntoARemoteMarkedTabHidesItsRingToo() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@lab.tail1.ts.net")).named("lab")
        let ssh = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                    paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-tab-attention-remote-unused")),
                                    environment: { [:] })
        services.machines.add(ssh)
        let remote = ssh.daemon.store
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "GitHub")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        remote.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "lab work", screens: [screen])]))
        let workspace = try #require(remote.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        tab.applyState(SessionStateMirror.TabRecord(attention: Self.attention("Log in to GitHub", at: 1_000)), progress: nil)
        #expect(NotificationCenterService.tab(id: tab.id, in: services.daemon.store) == nil, "the tab is on the SSH machine, not this Mac")
        let notifications = services.notifications
        #expect(notifications.attentionMarks(for: workspace).count == 1, "the remote marked tab has no ring")
        notifications.interacted(.focus, tabID: tab.id)
        #expect(notifications.attentionMarks(for: workspace).count == 1, "focus alone hid the ring")
        notifications.interacted(.click, tabID: tab.id)
        #expect(notifications.attentionMarks(for: workspace).isEmpty, "a click into the remote tab left its ring")
        #expect(tab.showsUnread, "going in keeps the mark")
    }
}
