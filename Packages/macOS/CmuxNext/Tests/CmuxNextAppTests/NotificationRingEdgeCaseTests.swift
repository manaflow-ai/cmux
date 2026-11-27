import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing

/// "I click a terminal that has a notification and it doesn't dismiss it" (Lawrence, 2026-10-31).
/// One rule for every ring, dot and badge: a tab's unread notification is read when the person
/// sees its surface (clicks or types into its pane, opens it, or looks at it in the key window
/// while cmux is active, under the default `focus` dismissal), on whichever machine holds it, and
/// every indicator reads that one state (``TabModel/hasUnread``). plans/cmux-next/notification-rings.md
/// lists the edge cases; the ones a Mac-local tab already passed are in UnreadRingClickReadTests,
/// UnreadRingDismissTests and TabAttentionTests. These cover what failed: a tab on another machine
/// (a remote group's SSH machine, a Cloud machine) only hid an agent's attention ring, so its
/// notification rang on after every click, key, open and look.
@MainActor
@Suite(.serialized)
struct NotificationRingEdgeCaseTests {
    private static let capabilities = #"["state-resources-v1","tab-mark-unread-v1","notification-ack-v1"]"#

    /// A workspace with one terminal holding unread notification `id`, in `store` (same ids on
    /// every machine: a forked machine keeps its tab ids).
    private static func unreadWorkspace(in store: DaemonStore, name: String, id: UInt64,
                                        capabilities: String = Self.capabilities) throws -> (WorkspaceModel, TabModel) {
        let marker = TabNotification(notification: NotificationID(rawValue: id), unread: true, level: .info, source: "terminal")
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_forked", title: "~", notification: marker)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: name), name: name, screens: [screen])]))
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"\#(name)","generation":"g1","capabilities":\#(capabilities)}"#.utf8))
        store.noteHandshake(identity)
        let workspace = try #require(store.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        try #require(tab.hasUnread)
        return (workspace, tab)
    }

    private struct Machines {
        let services: AppServices
        let ssh: SSHMachineSession
        let remoteWorkspace: WorkspaceModel
        let remoteTab: TabModel
        let localWorkspace: WorkspaceModel
        let localTab: TabModel
    }

    private static func machines(_ name: String, remoteCapabilities: String = Self.capabilities,
                                 appActive: Bool = false) throws -> Machines {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), keyWindowSource: { nil }, appActiveSource: { appActive }, heldKeyReplay: { event, _, _ in NSApp?.sendEvent(event) })
        let host = try SSHHost(destination: SSHDestination(parsing: "lawrence@cmux-lawrence.tail1.ts.net")).named("cmux-lawrence")
        let ssh = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                    paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-ring-edge-\(name)-unused")),
                                    environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        services.machines.add(ssh)
        let (remoteWorkspace, remoteTab) = try unreadWorkspace(in: ssh.daemon.store, name: "remote-\(name)", id: 7,
                                                               capabilities: remoteCapabilities)
        let (localWorkspace, localTab) = try unreadWorkspace(in: services.daemon.store, name: "local-\(name)", id: 7)
        try #require(remoteTab.id == localTab.id && remoteTab !== localTab, "the two machines' tabs share an id")
        return Machines(services: services, ssh: ssh, remoteWorkspace: remoteWorkspace, remoteTab: remoteTab,
                        localWorkspace: localWorkspace, localTab: localTab)
    }

    /// Edge case: a click into a remote group's terminal. Its ring, tab dot and row dot go at once
    /// (the ack goes to that machine's daemon); this Mac's tab with the same id keeps all of them.
    @Test func aClickInARemoteTerminalReadsItsNotification() throws {
        let m = try Self.machines("click")
        let notifications = m.services.notifications
        #expect(notifications.attentionMarks(for: m.remoteWorkspace).count == 1, "the remote unread terminal has no ring")
        notifications.interacted(.click, tabID: m.remoteTab.id, in: m.remoteWorkspace, local: false)
        #expect(!m.remoteTab.hasUnread, "a click into the remote terminal kept its notification unread")
        #expect(notifications.attentionMarks(for: m.remoteWorkspace).isEmpty, "a click into the remote terminal kept its ring")
        #expect(notifications.log.contains("ack \(m.remoteTab.id) on \(m.ssh.daemon.machineID)"), "the read never went to the remote daemon")
        #expect(m.localTab.hasUnread, "a click on the remote tab read this Mac's tab that shares its id")
        #expect(notifications.attentionMarks(for: m.localWorkspace).count == 1, "a click on the remote tab cleared this Mac's ring")
        #expect(!notifications.log.contains("ack \(m.localTab.id)"), "the remote click acknowledged on this Mac's daemon")
    }

    /// Edge case: typing into a remote terminal (the key router's target names its own store).
    @Test func typingInARemoteTerminalReadsItsNotification() throws {
        let m = try Self.machines("key")
        let target = TabInteractionTarget(tab: m.remoteTab, store: m.ssh.daemon.store, local: false)
        m.services.notifications.interacted(.keystroke, target: target)
        #expect(!m.remoteTab.hasUnread, "typing into the remote terminal kept its notification unread")
        #expect(m.localTab.hasUnread, "typing on the remote tab read this Mac's tab that shares its id")
    }

    /// Edge case: Jump to Unread / Open Notification on a remote tab.
    @Test func openingARemoteNotificationReadsIt() throws {
        let m = try Self.machines("open")
        m.services.notifications.opened(m.remoteTab)
        #expect(!m.remoteTab.hasUnread, "opening the remote notification kept it unread")
        #expect(m.localTab.hasUnread)
    }

    /// Edge case: a remote daemon older than notification-ack-v1 cannot be told. Nothing is sent
    /// (an ack it refuses would flash the ring off and back), and the log says why.
    @Test func aRemoteDaemonWithoutAckKeepsItsMarkAndSaysWhy() throws {
        let m = try Self.machines("old", remoteCapabilities: #"["state-resources-v1"]"#)
        let notifications = m.services.notifications
        notifications.interacted(.click, tabID: m.remoteTab.id, in: m.remoteWorkspace, local: false)
        #expect(m.remoteTab.hasUnread)
        #expect(!notifications.log.contains { $0.hasPrefix("ack ") })
        #expect(notifications.log.contains { $0.contains("cannot read \(m.remoteTab.id)") && $0.contains("notification-ack-v1") })
    }

    /// Edge case: the dismissal policy holds on every machine: under `keystroke` a click reads
    /// neither this Mac's terminal nor a remote one, and a key reads both.
    @Test func thePolicyIsTheSameOnEveryMachine() throws {
        let m = try Self.machines("policy")
        let notifications = m.services.notifications
        notifications.preferences.dismissal = .keystroke
        notifications.interacted(.click, tabID: m.remoteTab.id, in: m.remoteWorkspace, local: false)
        notifications.interacted(.click, tabID: m.localTab.id, in: m.localWorkspace, local: true)
        #expect(m.remoteTab.hasUnread && m.localTab.hasUnread, "a click read under the keystroke dismissal")
        notifications.interacted(.keystroke, tabID: m.remoteTab.id, in: m.remoteWorkspace, local: false)
        notifications.interacted(.keystroke, tabID: m.localTab.id, in: m.localWorkspace, local: true)
        #expect(!m.remoteTab.hasUnread && !m.localTab.hasUnread, "a key did not read under the keystroke dismissal")
    }

    /// Edge case: looking at a remote terminal (its window key, cmux active) is a look, as on
    /// this Mac: the viewed-tab rule finds it, so a notification that lands there while the person
    /// watches, or one waiting when they switch to it, is read under the `focus` dismissal.
    @Test func aViewedRemoteTerminalIsViewed() async throws {
        let m = try Self.machines("viewed", appActive: true)
        AppActions.bind(m.services)
        m.services.windows.ordersWindowsIn = false
        let controller = try #require(m.services.windows.openWindow(workspaces: [m.remoteWorkspace.id],
                                                                   frame: CGRect(x: 200, y: 200, width: 1000, height: 700)))
        let window = try #require(controller.window)
        defer { controller.teardown(); window.close() }
        try await PinnedPageTests.until({ controller.content?.panes.isEmpty == false && controller.focus.state.pane != nil })
        try #require(controller.content?.workspace === m.remoteWorkspace)
        controller.focus.send(.windowKey(true))
        try await PinnedPageTests.until({ controller.focus.state.windowKey })
        let viewed = m.services.notifications.viewedTabs(m.services.daemon.store)
        #expect(viewed.contains { $0 === m.remoteTab }, "the remote terminal in the key window was not viewed")
        #expect(!viewed.contains { $0 === m.localTab }, "this Mac's same-id tab counted as viewed")
    }
}
