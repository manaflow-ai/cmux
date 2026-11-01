import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextRemote
import CmuxNextSidebar
import CmuxNextWakeups
@testable import CmuxNextDaemon
import Foundation
import Observation
import Testing

/// tab-attention-v1: an agent marks the tab where the person must act. The tab, its workspace
/// row and its pane show the existing unread treatment (the blue dot and ring, no new dot); the
/// row says why; going into the pane hides the ring but keeps the dot; a new request rings again.
@MainActor
@Suite struct TabAttentionTests {
    /// Set by an observation's onChange, which runs synchronously on the mutating (main) thread.
    private nonisolated final class Woke: @unchecked Sendable { var value = false }

    private static func attention(_ reason: String, at: UInt64, requestID: String? = nil) -> TabAttention {
        TabAttention(reason: reason, atMs: at, requestID: requestID ?? String(format: "%032llx", at))
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
        let value = JSONValue.object(["reason": .string("Confirm GitHub access"), "at_ms": .number(1_729_000_000_000), "request_id": .string(String(format: "%032llx", UInt64(1_729_000_000_000)))])
        #expect(TabAttention(value) == Self.attention("Confirm GitHub access", at: 1_729_000_000_000))
        #expect(TabAttention(.object(["reason": .string("")])) == nil, "an empty reason is no mark")
        #expect(TabAttention(.string("x")) == nil)
        #expect(TabAttention(nil) == nil)
        for bad: JSONValue? in [nil, .string("1000"), .number(-1), .number(1.5), .number(.nan), .number(.infinity)] {
            var record: [String: JSONValue] = ["reason": .string("Confirm GitHub access")]
            record["at_ms"] = bad
            #expect(TabAttention(.object(record)) == nil, "at_ms \(String(describing: bad)) read as a request")
        }
    }

    @Test func requestIdentityIsStrictAndLegacyMarksCannotBeCleared() throws {
        for bad: JSONValue in [.string("short"), .string(String(repeating: "A", count: 32)), .number(1), .null] {
            #expect(TabAttention(.object(["reason": .string("Confirm"), "at_ms": .number(1_000), "request_id": bad])) == nil)
        }
        let (_, _, tab) = try Self.marked()
        let legacy = try #require(TabAttention(.object(["reason": .string("Confirm"), "at_ms": .number(1_000)])))
        #expect(legacy.requestID == nil)
        tab.applyState(SessionStateMirror.TabRecord(attention: legacy), progress: nil)
        #expect(tab.expectAttentionClear() == nil, "legacy marks must not use an unconditional clear")
        #expect(tab.attention == legacy)
    }

    @Test func identicalTimeAndReasonReplacementCannotInheritADismissalOrClear() throws {
        let store = DaemonStore()
        let (workspace, tab) = try Self.markedWorkspace(in: store, name: "same time", reason: "Confirm")
        let service = NotificationCenterService()
        let original = try #require(tab.attention)
        let pressed = TabInteractionTarget(tab: tab, store: store, local: false)
        let firstGeneration = tab.attentionGeneration
        service.interacted(.click, tab: tab)
        #expect(service.attentionMarks(for: workspace).isEmpty)
        let pending = try #require(tab.expectAttentionClear())
        // The clear and re-mark can collapse into one owner snapshot; there may be no nil echo.
        let replacement = Self.attention(original.reason, at: original.atMs, requestID: String(repeating: "b", count: 32))
        tab.applyState(SessionStateMirror.TabRecord(attention: replacement), progress: nil)
        #expect(tab.attentionGeneration != firstGeneration)
        tab.dropExpectedAttentionClear(pending)
        service.interacted(.click, target: pressed)
        #expect(tab.attention == replacement, "a failed clear of A overwrote B")
        #expect(service.attentionMarks(for: workspace).count == 1, "A's delayed click hid B's ring")
        let generation = tab.attentionGeneration
        tab.applyState(SessionStateMirror.TabRecord(attention: replacement), progress: nil)
        #expect(tab.attentionGeneration == generation, "replaying an owner snapshot minted a new request")
        service.interacted(.click, tab: tab)
        tab.applyState(SessionStateMirror.TabRecord(), progress: nil)
        let sameTimeAgain = Self.attention(original.reason, at: original.atMs, requestID: String(repeating: "c", count: 32))
        tab.applyState(SessionStateMirror.TabRecord(attention: sameTimeAgain), progress: nil)
        #expect(service.attentionMarks(for: workspace).count == 1, "clear/re-mark inherited B's dismissal")
        service.interacted(.click, tab: tab)
        let rolledBackClock = Self.attention(original.reason, at: 1, requestID: String(repeating: "d", count: 32))
        tab.applyState(SessionStateMirror.TabRecord(attention: rolledBackClock), progress: nil)
        #expect(service.attentionMarks(for: workspace).count == 1, "clock rollback hid the next request")
    }

    @Test func restartedViewShowsThePersistedRequestAndMissingCapabilityCannotClearIt() throws {
        let (service, workspace, tab) = try Self.marked()
        service.interacted(.click, tab: tab)
        #expect(service.attentionMarks(for: workspace).isEmpty)
        let (restartedService, restartedWorkspace, restartedTab) = try Self.marked()
        #expect(restartedTab.attention?.requestID == tab.attention?.requestID)
        #expect(restartedService.attentionMarks(for: restartedWorkspace).count == 1)
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(throws: ActionFailure.self) {
            try TabUnreadMark.clearAttention(tab: restartedTab, daemon: services.daemon)
        }
        #expect(restartedTab.attention != nil, "missing capability optimistically cleared a mark")
    }

    @Test func aMarkedTabShowsUnreadUntilTheRecordDropsIt() throws {
        let (_, _, tab) = try Self.marked()
        #expect(tab.showsUnread, "the tab's dot and the screen bar read showsUnread")
        #expect(!tab.markedUnread && !tab.hasUnread, "the mark is not Mark as Unread or a notification")
        tab.applyState(SessionStateMirror.TabRecord(), progress: nil)
        #expect(tab.attention == nil)
        #expect(!tab.showsUnread)
    }

    @Test func anAttentionClearReconcilesEchoesAndOnlyRollsBackItsOwnRequest() throws {
        let (_, _, tab) = try Self.marked()
        let original = try #require(tab.attention)
        let cleared = try #require(tab.expectAttentionClear())
        #expect(!tab.showsUnread)
        tab.applyState(SessionStateMirror.TabRecord(attention: original), progress: nil)
        #expect(!tab.showsUnread, "an older echo restored the cleared request")
        let newer = Self.attention("Approve a new demo", at: 2_000)
        tab.applyState(SessionStateMirror.TabRecord(attention: newer), progress: nil)
        tab.dropExpectedAttentionClear(cleared)
        #expect(tab.attention == newer, "the failed old clear overwrote a newer request")
        let second = try #require(tab.expectAttentionClear())
        tab.dropExpectedAttentionClear(second)
        #expect(tab.attention == newer, "a failed clear did not restore its own request")
        _ = tab.expectAttentionClear()
        tab.applyState(SessionStateMirror.TabRecord(), progress: nil)
        #expect(!tab.showsUnread, "the clear's owner echo restored its request")
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
        // The pane's ring redraws from an observation of attentionMarks: hiding the ring must wake it.
        let woke = Woke()
        withObservationTracking { _ = service.attentionMarks(for: workspace) } onChange: { woke.value = true }
        service.interacted(.click, tab: tab)
        #expect(woke.value, "hiding the ring did not wake the ring's observers")
        #expect(service.attentionMarks(for: workspace).isEmpty, "going into the pane left the ring")
        #expect(tab.showsUnread, "going in keeps the mark: only the agent, a navigation or a close clears it")
        tab.applyState(SessionStateMirror.TabRecord(attention: Self.attention("Approve the deploy", at: 2_000)), progress: nil)
        #expect(service.attentionMarks(for: workspace).count == 1, "a new request did not ring again")
        service.dismissHighlight(workspace)
        #expect(service.attentionMarks(for: workspace).isEmpty, "Dismiss Highlight left the ring")
        // Jumping to it (jump to unread, a banner) goes in as a click does.
        tab.applyState(SessionStateMirror.TabRecord(attention: Self.attention("Approve again", at: 3_000)), progress: nil)
        #expect(service.attentionMarks(for: workspace).count == 1)
        service.interacted(.open, tab: tab)
        #expect(service.attentionMarks(for: workspace).isEmpty, "opening the marked tab left its ring")
    }

    /// An older daemon's mark has no request id. Its owner clear stays refused, but going in and
    /// Dismiss Highlight still hide its ring, and a press on a mark since replaced hides nothing.
    @Test func aLegacyMarksRingHidesOnEntryAndDismissHighlight() throws {
        _ = NSApplication.shared
        let store = DaemonStore()
        let (workspace, tab) = try Self.markedWorkspace(in: store, name: "legacy", reason: "Confirm GitHub access")
        let service = NotificationCenterService()
        let legacy = TabAttention(reason: "Confirm GitHub access", atMs: 1_500)
        tab.applyState(SessionStateMirror.TabRecord(attention: legacy), progress: nil)
        #expect(tab.attention?.requestID == nil)
        #expect(service.attentionMarks(for: workspace).count == 1, "the legacy mark has no ring")
        service.interacted(.click, tab: tab)
        #expect(service.attentionMarks(for: workspace).isEmpty, "going in left the legacy mark's ring")
        #expect(tab.showsUnread, "going in keeps the legacy mark")
        tab.applyState(SessionStateMirror.TabRecord(attention: TabAttention(reason: "Approve the deploy", atMs: 2_000)), progress: nil)
        #expect(service.attentionMarks(for: workspace).count == 1, "a new legacy request did not ring again")
        service.dismissHighlight(workspace)
        #expect(service.attentionMarks(for: workspace).isEmpty, "Dismiss Highlight left the legacy mark's ring")
        let pressed = TabInteractionTarget(tab: tab, store: store, local: true)
        tab.applyState(SessionStateMirror.TabRecord(attention: TabAttention(reason: "Approve the deploy", atMs: 3_000)), progress: nil)
        service.interacted(.click, target: pressed)
        #expect(service.attentionMarks(for: workspace).count == 1, "a press on a replaced legacy mark hid the new ring")
    }

    /// A marked tab in `store`'s one workspace, with the same id on every store.
    private static func markedWorkspace(in store: DaemonStore, name: String, reason: String,
                                        markedUnread: Bool = false) throws -> (WorkspaceModel, TabModel) {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_forked", title: "GitHub")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: name), name: name, screens: [screen])]))
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"attention-test","generation":"g1","capabilities":["state-resources-v1","tab-mark-unread-v1","tab-attention-v1","tab-attention-request-id-v1"]}"#.utf8))
        store.noteHandshake(identity)
        let workspace = try #require(store.workspaces.first)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        tab.applyState(SessionStateMirror.TabRecord(markedUnread: markedUnread, attention: Self.attention(reason, at: 1_000)), progress: nil)
        return (workspace, tab)
    }

    @Test func pinnedRemoteDismissalKeepsLocalHighlight() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@lab.tail1.ts.net")).named("lab")
        let ssh = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                    paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-tab-attention-dismiss-unused")),
                                    environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        services.machines.add(ssh)
        let (remote, remoteTab) = try Self.markedWorkspace(in: ssh.daemon.store, name: "remote", reason: "Remote", markedUnread: true)
        let (local, localTab) = try Self.markedWorkspace(in: services.daemon.store, name: "local", reason: "Local", markedUnread: true)
        // Equal IDs and mark generations must still have independent dismissal state.
        #expect(remoteTab.id == localTab.id && remoteTab.markedUnreadGeneration == localTab.markedUnreadGeneration)
        AppActions.bind(services)
        let notifications = services.notifications
        // Pinned tiles are absent from the list model; their layout reference supplies the owner.
        let menu = try #require(SidebarContextMenus.menu(for: .workspaces([CmuxNextSidebar.WorkspaceID(remote.id)]),
                                                       model: SidebarModel(), services: services, scope: ThemeScope(level: .room),
                                                       workspaceMachineID: ssh.daemon.machineID))
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(items) }
        let dismiss = try #require(items(menu).first { ActionRegistry.menuRun(of: $0)?.id == "notifications.dismissHighlight" })
        let action = try #require(dismiss.action)
        #expect(NSApp.sendAction(action, to: dismiss.target, from: dismiss))
        #expect(!notifications.hasHighlight(remote), "the pinned remote workspace kept its ring")
        // Drop attention so this assertion specifically checks the independent manual-mark ring.
        localTab.applyState(SessionStateMirror.TabRecord(markedUnread: true), progress: nil)
        #expect(notifications.hasHighlight(local), "remote dismissal hid the local manual mark")
        notifications.dismissHighlight(local)
        #expect(!notifications.hasHighlight(local))
        remoteTab.applyState(SessionStateMirror.TabRecord(markedUnread: false), progress: nil)
        remoteTab.applyState(SessionStateMirror.TabRecord(markedUnread: true), progress: nil)
        #expect(notifications.hasHighlight(remote), "a new remote mark did not ring again")
        #expect(!notifications.hasHighlight(local), "a remote re-mark revived the local ring")
    }

    /// A tab on this Mac and one on an SSH machine with the same id (a forked machine keeps its
    /// tab ids): going into the remote one hides only its ring, and Dismiss Highlight on one
    /// workspace leaves the other's.
    @Test func goingIntoARemoteMarkedTabHidesOnlyItsOwnRing() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@lab.tail1.ts.net")).named("lab")
        let ssh = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                    paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-tab-attention-remote-unused")),
                                    environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        services.machines.add(ssh)
        let (remoteWorkspace, remoteTab) = try Self.markedWorkspace(in: ssh.daemon.store, name: "lab work", reason: "Log in to GitHub")
        let (localWorkspace, localTab) = try Self.markedWorkspace(in: services.daemon.store, name: "coord", reason: "Confirm access",
                                                                      markedUnread: true)
        #expect(remoteTab.id == localTab.id && remoteTab !== localTab, "the two machines' tabs share an id")
        let notifications = services.notifications
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: remoteWorkspace.id))
        invocation.targetMachineID = ssh.daemon.machineID
        #expect(ActionScope(services: services, invocation: invocation).workspace === remoteWorkspace)
        invocation.targetMachineID = "disconnected-machine"
        #expect(ActionScope(services: services, invocation: invocation).workspace == nil)
        #expect(notifications.attentionMarks(for: remoteWorkspace).count == 1, "the remote marked tab has no ring")
        notifications.interacted(.focus, tabID: remoteTab.id, in: remoteWorkspace, local: false)
        #expect(notifications.attentionMarks(for: remoteWorkspace).count == 1, "focus alone hid the ring")
        notifications.interacted(.click, tabID: remoteTab.id, in: remoteWorkspace, local: false)
        #expect(notifications.attentionMarks(for: remoteWorkspace).isEmpty, "a click into the remote tab left its ring")
        #expect(remoteTab.attention != nil, "going in keeps the mark")
        #expect(localTab.markedUnread, "a click on the remote tab read this Mac's tab that shares its id")
        #expect(notifications.attentionMarks(for: localWorkspace).count == 1, "a click on the remote tab hid this Mac's ring")
        remoteTab.applyState(SessionStateMirror.TabRecord(attention: Self.attention("Log in again", at: 2_000)), progress: nil)
        notifications.dismissHighlight(localWorkspace)
        #expect(notifications.attentionMarks(for: localWorkspace).isEmpty, "Dismiss Highlight left the ring")
        #expect(notifications.attentionMarks(for: remoteWorkspace).count == 1, "Dismiss Highlight here hid the remote ring")

        // A strip click is delayed until mouse-up. A titlebar tracking loop can consume that
        // mouse-up, so it reaches the service in screen coordinates with no window. The click
        // must still read the originating remote tab rather than this Mac's tab with the same id.
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        notifications.leftButtonIsDown = { true }
        let controller = try #require(services.windows.openWindow(workspaces: [remoteWorkspace.id],
                                                                 frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        let window = try #require(controller.window)
        defer { controller.teardown(); window.close() }
        try await PinnedPageTests.until({ controller.content?.panes.isEmpty == false })
        let content = try #require(controller.content)
        try #require(content.workspace === remoteWorkspace)
        let strip = try #require(content.panes.values.first?.view.stripView)
        content.contentView.layoutSubtreeIfNeeded()
        let point = strip.convert(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil)
        notifications.noteMouseDown(in: window, at: point, synthetic: true)
        #expect(notifications.attentionMarks(for: remoteWorkspace).count == 1, "the strip press read before mouse-up")
        notifications.noteMouseUp(in: nil, at: window.convertPoint(toScreen: point))
        #expect(notifications.attentionMarks(for: remoteWorkspace).isEmpty, "the remote strip click left its ring")
        #expect(localTab.markedUnread, "the remote strip click read this Mac's tab with the same id")

        // A new owner request can arrive between native mouse-down and mouse-up without a nil
        // snapshot, even with the same reason and timestamp. The release still belongs to A.
        let pressedRequest = Self.attention("Confirm remote access", at: 2_500, requestID: String(repeating: "a", count: 32))
        remoteTab.applyState(SessionStateMirror.TabRecord(attention: pressedRequest), progress: nil)
        notifications.noteMouseDown(in: window, at: point, synthetic: true)
        let replacementRequest = Self.attention(pressedRequest.reason, at: pressedRequest.atMs, requestID: String(repeating: "b", count: 32))
        remoteTab.applyState(SessionStateMirror.TabRecord(attention: replacementRequest), progress: nil)
        notifications.noteMouseUp(in: nil, at: window.convertPoint(toScreen: point))
        #expect(remoteTab.attention == replacementRequest)
        #expect(notifications.attentionMarks(for: remoteWorkspace).count == 1, "A's native release dismissed replacement B")

        // Resolve the delayed click against the model pressed, even if a shortcut changes the
        // window's workspace while the button stays down.
        remoteTab.applyState(SessionStateMirror.TabRecord(attention: Self.attention("Confirm remote access", at: 3_000)), progress: nil)
        localTab.applyState(SessionStateMirror.TabRecord(markedUnread: true, attention: Self.attention("Confirm local access", at: 4_000)), progress: nil)
        notifications.noteMouseDown(in: window, at: point, synthetic: true)
        services.windows.moveWorkspaces([localWorkspace.id], toWindow: controller.state.id, select: true)
        controller.showWorkspace(requested: localWorkspace.id)
        try #require(controller.content?.workspace === localWorkspace)
        notifications.noteMouseUp(in: nil, at: window.convertPoint(toScreen: point))
        #expect(notifications.attentionMarks(for: remoteWorkspace).isEmpty, "workspace replacement lost the pressed remote tab")
        #expect(localTab.attentionRingHiddenThrough != localTab.attentionGeneration, "workspace replacement redirected the press into the local tab")
        #expect(localTab.markedUnread)

        // Mark Tab Unread is a palette/CLI action and is intentionally omitted from the compact
        // pointer menu. The click and owner-request checks above cover the menu's visible ring
        // behavior without requiring an action that the menu contract excludes.
    }
}
