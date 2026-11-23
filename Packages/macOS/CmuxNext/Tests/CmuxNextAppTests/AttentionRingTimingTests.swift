import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextBridge
@testable import CmuxNextLayout
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/46908: the attention ring of the pane the person goes into
/// blinks out in the pass that takes them there, whatever else is still on its way (the focus machine's
/// settle, the viewed-tab rules, the daemon's read, a chat page loading). Going in is a focus move into the
/// pane, its workspace coming on screen with the pane focused, or a click on it, also on its tab strip and
/// also when it already has the focus. Before, only a focus move inside the shown layout or a click on the
/// pane's content entered it: a workspace switch (its layout's focus does not move) drew the ring at once
/// and left it until the later passes, and a press on the sidebar row kept even the focus move from entering.
@MainActor
@Suite(.serialized)
struct AttentionRingTimingTests {
    /// Workspace `a`: one quiet terminal. Workspace `b`: one pane, its tab holding an unread notification.
    private static func tree() -> DaemonTree {
        let marker = TabNotification(notification: NotificationID(rawValue: 11), unread: true, level: .info, source: "terminal")
        let quiet = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let ringing = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~", notification: marker)])
        let a = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(quiet.id), panes: [quiet])
        let b = ScreenSnapshot(id: ScreenID(rawValue: 2), layout: .leaf(ringing.id), panes: [ringing])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ring-timing-a"), name: "a", screens: [a]),
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: WorkspaceKey(rawValue: "ring-timing-b"), name: "b", screens: [b]),
        ])
        tree.personal = PersonalState(workspaces: [
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "ring-timing-a"), index: 0),
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "ring-timing-b"), index: 1),
        ])
        return tree
    }

    private struct Fixture {
        let services: AppServices
        let controller: WindowController
        let window: NSWindow
        let a: WorkspaceModel
        let b: WorkspaceModel
        /// `b`'s one pane, which rings.
        let ringing: PaneModel

        func close() {
            services.appActiveSource = { true }
            controller.teardown()
            window.close()
        }
    }

    /// One window listing `a` and `b`, showing `a` with its window key. `active`: whether cmux is active.
    private static func open(active: Bool) async throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), keyWindowSource: { nil }, appActiveSource: { active },
                                   heldKeyReplay: { event, _, _ in NSApp?.sendEvent(event) })
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let a = try #require(store.workspaces.first { $0.name == "a" })
        let b = try #require(store.workspaces.first { $0.name == "b" })
        let ringing = try #require(b.screens.first?.panes.first)
        let controller = try #require(services.windows.openWindow(workspaces: [a.id, b.id], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        let window = try #require(controller.window)
        controller.showWorkspace(requested: a.id)
        try await PinnedPageTests.until({ controller.content?.workspace === a && controller.focus.state.pane != nil },
                                        report: { "the window never showed workspace a" })
        controller.focus.send(.windowKey(true))
        try await PinnedPageTests.until({ controller.focus.state.windowKey })
        return Fixture(services: services, controller: controller, window: window, a: a, b: b, ringing: ringing)
    }

    /// Cases 1 and 2 of the issue: switching back to a workspace whose focused pane rang while it was
    /// hidden. Its layout keeps its focus, so no focus move came: the ring was drawn with the workspace,
    /// before the focus machine settled on it, and stayed until the viewed-tab rules and the read came back.
    @Test func switchingToAWorkspaceBlinksItsFocusedPanesRingOutInTheSwitchsPass() async throws {
        let fixture = try await Self.open(active: false)
        defer { fixture.close() }
        let pane = LayoutPaneID(fixture.ringing.id)
        // `b` shows once while cmux is in the back (nothing is looked at, so its ring stays), then is parked.
        fixture.controller.showWorkspace(requested: fixture.b.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.b && fixture.controller.content?.layoutModel.focusedPane == pane },
                                        report: { "workspace b never showed with its pane focused" })
        let model = try #require(fixture.controller.content?.layoutModel)
        try await PinnedPageTests.until({ model.attention[pane] != nil }, report: { "b's unread pane never rang" })
        fixture.controller.showWorkspace(requested: fixture.a.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.a && fixture.controller.focus.state.pane != fixture.ringing.id })
        #expect(fixture.controller.parked[fixture.b.id]?.layoutModel === model, "b was not kept parked")
        fixture.services.appActiveSource = { true }

        fixture.controller.showWorkspace(requested: fixture.b.id)
        // The same pass: no await between the switch and these reads.
        #expect(fixture.controller.content?.layoutModel === model, "b did not come back from its parked content")
        #expect(model.attention[pane] == nil, "switching to b drew its focused pane's ring, left for a later pass")
        #expect(model.attentionReadByEntry.contains(pane), "the switch took the ring without the dismiss blink")
        try await PinnedPageTests.until({ fixture.ringing.tabs.first?.showsUnread == false }, report: { "the switch left b's blue dot" })
        #expect(model.attention[pane] == nil, "the ring came back after the read")
    }

    /// Case 2 of the issue, from the sidebar: a press on b's row switches to it. The press is on the
    /// sidebar, not on the pane, so it is no click that reads the pane later: the pane is gone into now.
    @Test func switchingFromASidebarPressBlinksTheShownPanesRingOut() async throws {
        let fixture = try await Self.open(active: true)
        defer { fixture.close() }
        let pane = LayoutPaneID(fixture.ringing.id)
        // A real left press being dispatched, outside every pane (where the sidebar row is).
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: -20, y: -20), modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.postEvent(down, atStart: true)
        _ = NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast, inMode: .default, dequeue: true)
        try #require(NSApp.currentEvent?.type == .leftMouseDown, "no press is being dispatched")

        fixture.controller.showWorkspace(requested: fixture.b.id)
        let model = try #require(fixture.controller.content?.layoutModel)
        #expect(fixture.controller.content?.workspace === fixture.b, "the switch did not show b")
        #expect(model.attention[pane] == nil, "a sidebar press kept the shown pane's ring for a later pass")
        #expect(model.attentionReadByEntry.contains(pane), "the switch took the ring without the dismiss blink")
        try await PinnedPageTests.until({ fixture.ringing.tabs.first?.showsUnread == false }, report: { "the switch left b's blue dot" })
    }

    /// Case 3 of the issue: the ringing pane already has the focus (it rang while cmux was in the back),
    /// and the person clicks its tab. No focus moves; the click on the strip reads the pane on its
    /// mouse-up, and its ring blinks out then, not when the daemon's read comes back.
    @Test func clickingTheFocusedRingingPanesTabBlinksItsRingOut() async throws {
        let fixture = try await Self.open(active: false)
        defer { fixture.close() }
        let pane = LayoutPaneID(fixture.ringing.id)
        fixture.controller.showWorkspace(requested: fixture.b.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.b && fixture.controller.focus.state.pane == fixture.ringing.id },
                                        report: { "workspace b never showed with its pane focused" })
        let content = try #require(fixture.controller.content)
        let model = content.layoutModel
        try await PinnedPageTests.until({ model.attention[pane] != nil }, report: { "b's unread pane never rang" })
        content.contentView.layoutSubtreeIfNeeded()
        let strip = try #require(content.panes[pane]?.view.stripView, "the pane has no tab strip")
        try #require(strip.window === fixture.window && !strip.isHiddenOrHasHiddenAncestor && strip.bounds.width > 0, "the pane shows no tab strip")
        let point = strip.convert(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil)
        fixture.services.appActiveSource = { true }
        #expect(model.attention[pane] != nil, "the focused pane stopped ringing before the click")

        let notifications = fixture.services.notifications
        notifications.noteMouseDown(in: fixture.window, at: point, synthetic: true)
        #expect(model.attention[pane] != nil, "the press on the tab read the pane before its mouse-up (a drag keeps the ring)")
        notifications.noteMouseUp(in: fixture.window, at: point)
        #expect(model.attention[pane] == nil, "clicking the focused pane's tab left its ring for a later pass")
        #expect(model.attentionReadByEntry.contains(pane), "the tab click took the ring without the dismiss blink")
        try await PinnedPageTests.until({ fixture.ringing.tabs.first?.showsUnread == false }, report: { "the tab click left the blue dot" })
    }
}
