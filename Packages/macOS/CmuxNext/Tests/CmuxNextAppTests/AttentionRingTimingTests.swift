import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextBridge
import CmuxNextDesign
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
    /// Workspace `a`: one quiet terminal (with `hiddenUnread`, a second tab behind it, unread: its blue dot shows on the
    /// strip, no ring). Workspace `b`: one pane, its tab holding an unread notification (with `bRings` false, none yet).
    private static func tree(hiddenUnread: Bool = false, bRings: Bool = true) -> DaemonTree {
        let marker = TabNotification(notification: NotificationID(rawValue: 11), unread: true, level: .info, source: "terminal")
        let hidden = TabSnapshot(surface: SurfaceID(rawValue: 3), title: "~", notification: TabNotification(notification: NotificationID(rawValue: 12), unread: true, level: .info, source: "terminal"))
        let quiet = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")] + (hiddenUnread ? [hidden] : []))
        let ringing = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~", notification: bRings ? marker : nil)])
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
    private static func open(active: Bool, hiddenUnread: Bool = false, bRings: Bool = true) async throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), keyWindowSource: { nil }, appActiveSource: { active },
                                   heldKeyReplay: { event, _, _ in NSApp?.sendEvent(event) })
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(hiddenUnread: hiddenUnread, bRings: bRings))
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

    /// The switch's own frame: switching back to b, whose ring stays (cmux is in the back, nothing reads it), draws
    /// no ring with that frame. The ring sits on the overlay window, which synced in the switch's pass, before b's
    /// pages and terminals drew: the ring showed on the old workspace's picture. It draws once that frame committed.
    @Test func switchingToAWorkspaceDrawsItsRingsOnlyAfterTheSwitchsFrame() async throws {
        let fixture = try await Self.open(active: false)
        defer { fixture.close() }
        let pane = LayoutPaneID(fixture.ringing.id)
        fixture.controller.showWorkspace(requested: fixture.b.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.b }, report: { "workspace b never showed" })
        let model = try #require(fixture.controller.content?.layoutModel)
        try await PinnedPageTests.until({ model.attention[pane] != nil }, report: { "b's unread pane never rang" })
        fixture.controller.showWorkspace(requested: fixture.a.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.a })

        fixture.controller.showWorkspace(requested: fixture.b.id)
        // The same pass: no await between the switch and these reads.
        #expect(fixture.controller.content?.layoutModel === model, "b did not come back from its parked content")
        #expect(model.attention[pane] != nil, "b's ring was read though nothing looks at it")
        #expect(model.holdsAttentionUntilShown, "the switch's own frame draws b's ring before b's content")
        let overlay = try #require(fixture.controller.content?.layoutView.context.hosts[pane]?.chrome, "b's pane has no overlay")
        #expect(overlay.attentionLayer.isHidden, "b's ring is on the overlay in the switch's own frame, over the old workspace")
        try await PinnedPageTests.until({ !model.holdsAttentionUntilShown }, report: { "b's ring never drew after the switch" })
        #expect(model.attention[pane] != nil, "b's ring went instead of drawing")
        #expect(!overlay.attentionLayer.isHidden, "b's ring stayed hidden after its frame")
    }

    /// The same switch with cmux active: the switch reads b's ring, and its dismiss blink still plays on the overlay,
    /// once the switch's frame lets the ring draw. Holding the rings must keep the overlay's mark, or the blink
    /// (which needs the ring it blinks out) never starts.
    @Test func switchingToAWorkspaceStillBlinksItsReadRingOnTheOverlay() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let fixture = try await Self.open(active: false)
        defer { fixture.close() }
        let pane = LayoutPaneID(fixture.ringing.id)
        fixture.controller.showWorkspace(requested: fixture.b.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.b }, report: { "workspace b never showed" })
        let model = try #require(fixture.controller.content?.layoutModel)
        let overlay = try #require(fixture.controller.content?.layoutView.context.hosts[pane]?.chrome, "b's pane has no overlay")
        try await PinnedPageTests.until({ model.attention[pane] != nil && overlay.attentionRingShown }, report: { "b's ring never drew" })
        fixture.controller.showWorkspace(requested: fixture.a.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.a && fixture.controller.focus.state.pane != fixture.ringing.id })
        fixture.services.appActiveSource = { true }

        fixture.controller.showWorkspace(requested: fixture.b.id)
        #expect(model.attention[pane] == nil && model.attentionReadByEntry.contains(pane), "the switch did not read b's ring")
        #expect(overlay.attentionLayer.isHidden, "the read ring blinks over the old workspace's frame")
        try await PinnedPageTests.until({ !model.holdsAttentionUntilShown }, report: { "the hold never ended" })
        try await PinnedPageTests.until({ overlay.attentionAnimationKeys.contains("attention-dismiss") },
                                        report: { "the switch took b's ring without the dismiss blink on the overlay" })
        #expect(!overlay.attentionLayer.isHidden, "the blink plays hidden")
    }

    /// Case 2 of the issue, from the sidebar: a press on b's row switches to it. The press is on the
    /// sidebar, not on the pane, so it is no click that reads the pane later: the pane is gone into now.
    @Test func switchingFromASidebarPressBlinksTheShownPanesRingOut() async throws {
        let fixture = try await Self.open(active: false)
        defer { fixture.close() }
        let pane = LayoutPaneID(fixture.ringing.id)
        // `b` shows once while cmux is in the back, so its ring draws, then is parked: the switch back has a ring to blink out.
        fixture.controller.showWorkspace(requested: fixture.b.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.b && fixture.controller.content?.layoutModel.focusedPane == pane },
                                        report: { "workspace b never showed with its pane focused" })
        let shown = try #require(fixture.controller.content?.layoutModel)
        try await PinnedPageTests.until({ shown.attention[pane] != nil }, report: { "b's unread pane never rang" })
        fixture.controller.showWorkspace(requested: fixture.a.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.a && fixture.controller.focus.state.pane != fixture.ringing.id })
        fixture.services.appActiveSource = { true }
        // A real left press being dispatched, outside every pane (where the sidebar row is).
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: -20, y: -20), modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.postEvent(down, atStart: true)
        _ = NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast, inMode: .default, dequeue: true)
        try #require(NSApp.currentEvent?.type == .leftMouseDown, "no press is being dispatched")

        fixture.controller.showWorkspace(requested: fixture.b.id)
        let model = try #require(fixture.controller.content?.layoutModel)
        #expect(model === shown, "b did not come back from its parked content")
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

    /// A press on the focused ringing pane's tab, while its agent replaces its attention request: the mouse-up was a
    /// click on the old request, so the new one keeps its ring (a press on request A never dismisses request B).
    @Test func aClickReleasedAfterTheRequestWasReplacedLeavesTheNewRing() async throws {
        let fixture = try await Self.open(active: false)
        defer { fixture.close() }
        let pane = LayoutPaneID(fixture.ringing.id)
        let tab = try #require(fixture.ringing.tabs.first)
        tab.applyState(SessionStateMirror.TabRecord(attention: TabAttention(reason: "Confirm A", atMs: 1_000, requestID: String(repeating: "a", count: 32))), progress: nil)
        fixture.controller.showWorkspace(requested: fixture.b.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.b && fixture.controller.focus.state.pane == fixture.ringing.id },
                                        report: { "workspace b never showed with its pane focused" })
        let content = try #require(fixture.controller.content)
        let model = content.layoutModel
        try await PinnedPageTests.until({ model.attention[pane] != nil }, report: { "b's pane never rang" })
        content.contentView.layoutSubtreeIfNeeded()
        let strip = try #require(content.panes[pane]?.view.stripView, "the pane has no tab strip")
        try #require(strip.window === fixture.window && !strip.isHiddenOrHasHiddenAncestor && strip.bounds.width > 0, "the pane shows no tab strip")
        let point = strip.convert(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil)
        fixture.services.appActiveSource = { true }

        let notifications = fixture.services.notifications
        notifications.noteMouseDown(in: fixture.window, at: point, synthetic: true)
        tab.applyState(SessionStateMirror.TabRecord(attention: TabAttention(reason: "Confirm B", atMs: 2_000, requestID: String(repeating: "b", count: 32))), progress: nil)
        try await PinnedPageTests.until({ model.attention[pane] != nil }, report: { "the new request did not ring" })
        notifications.noteMouseUp(in: fixture.window, at: point)
        #expect(model.attention[pane] != nil, "releasing a press on request A dismissed request B's ring")
        #expect(!model.attentionReadByEntry.contains(pane), "request B's ring blinked out for a click on request A")
        #expect(tab.attention?.requestID == String(repeating: "b", count: 32), "request B was cleared")
    }

    /// A press on tab A, and while it is down a key selects tab B in the same pane: the mouse-up is a click on A. It
    /// reads A only, never B, the tab the pane shows by then (going into the pane would read B).
    @Test func aClickReleasedAfterAnotherTabWasSelectedReadsOnlyThePressedTab() async throws {
        let fixture = try await Self.open(active: true, hiddenUnread: true)
        defer { fixture.close() }
        let content = try #require(fixture.controller.content)
        let paneModel = try #require(fixture.a.screens.first?.panes.first)
        let shown = try #require(paneModel.tabs.first)
        let unread = try #require(paneModel.tabs.first { $0.hasUnread }, "a has no unread tab behind the shown one")
        let pane = LayoutPaneID(paneModel.id)
        let model = content.layoutModel
        let strip = try #require(content.panes[pane], "a's pane has no controller")
        content.contentView.layoutSubtreeIfNeeded()
        let view = strip.view.stripView
        try #require(view.window === fixture.window && !view.isHiddenOrHasHiddenAncestor && view.bounds.width > 0, "the pane shows no tab strip")
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        #expect(strip.stripModel.selectedID?.rawValue == shown.id)

        let notifications = fixture.services.notifications
        notifications.noteMouseDown(in: fixture.window, at: point, synthetic: true)
        strip.stripModel.selectedID = StripTabID(unread.id) // a key selects B while the press on A is down
        notifications.noteMouseUp(in: fixture.window, at: point)
        #expect(!model.attentionReadByEntry.contains(pane), "releasing a press on A went into the pane, reading B")
        #expect(unread.showsUnread, "releasing a press on tab A read tab B")
    }

    /// Case 4: a tab behind the shown one is unread (its blue dot shows on the strip; its pane draws no ring, the shown
    /// tab is read). Clicking it shows it in the focused pane: the pane flashes the ring once and it blinks out, as going
    /// into a ringing pane does. Before, the tab was read on sight the moment it showed, so no ring was ever drawn to blink.
    @Test func clickingAnUnreadTabBehindTheShownOneFlashesItsPanesRingOnce() async throws {
        let fixture = try await Self.open(active: true, hiddenUnread: true)
        defer { fixture.close() }
        let content = try #require(fixture.controller.content)
        let paneModel = try #require(fixture.a.screens.first?.panes.first)
        let unread = try #require(paneModel.tabs.first { $0.hasUnread }, "a has no unread tab behind the shown one")
        let pane = LayoutPaneID(paneModel.id)
        let model = content.layoutModel
        let strip = try #require(content.panes[pane], "a's pane has no controller")
        content.contentView.layoutSubtreeIfNeeded()
        let view = strip.view.stripView
        try #require(view.window === fixture.window && !view.isHiddenOrHasHiddenAncestor && view.bounds.width > 0, "the pane shows no tab strip")
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        #expect(model.attention[pane] == nil, "the pane rang for a tab it does not show")

        // As AppKit dispatches the press on the tab: the strip selects the tab, then the press is noted.
        strip.stripModel.selectedID = StripTabID(unread.id)
        let notifications = fixture.services.notifications
        notifications.noteMouseDown(in: fixture.window, at: point, synthetic: true)
        try await PinnedPageTests.until({ model.attention[pane] != nil }, report: { "the clicked unread tab was read on sight: its pane never drew the ring to flash" })
        notifications.noteMouseUp(in: fixture.window, at: point)
        #expect(model.attention[pane] == nil, "the click's mouse-up left the ring")
        #expect(model.attentionReadByEntry.contains(pane), "the ring went without the flash")
        try await PinnedPageTests.until({ !unread.showsUnread }, report: { "the click left the tab's blue dot" })
    }

    /// Case 4, a quick click: the mouse-up comes in the same turn as the press, before the attention observation's next
    /// turn brings the ring the press's selection shows. Before, going in found no ring, so the click read the tab with no flash.
    @Test func aQuickClickOnAnUnreadTabBehindTheShownOneStillFlashesItsPanesRing() async throws {
        let fixture = try await Self.open(active: true, hiddenUnread: true)
        defer { fixture.close() }
        let content = try #require(fixture.controller.content)
        let paneModel = try #require(fixture.a.screens.first?.panes.first)
        let unread = try #require(paneModel.tabs.first { $0.hasUnread }, "a has no unread tab behind the shown one")
        let pane = LayoutPaneID(paneModel.id)
        let model = content.layoutModel
        let strip = try #require(content.panes[pane], "a's pane has no controller")
        content.contentView.layoutSubtreeIfNeeded()
        let view = strip.view.stripView
        try #require(view.window === fixture.window && !view.isHiddenOrHasHiddenAncestor && view.bounds.width > 0, "the pane shows no tab strip")
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        #expect(model.attention[pane] == nil, "the pane rang for a tab it does not show")

        // Press and release with no turn between them: the observation has not seen the selection yet.
        strip.stripModel.selectedID = StripTabID(unread.id)
        let notifications = fixture.services.notifications
        notifications.noteMouseDown(in: fixture.window, at: point, synthetic: true)
        notifications.noteMouseUp(in: fixture.window, at: point)
        #expect(model.attention[pane] == nil, "the quick click's mouse-up left the ring")
        #expect(model.attentionReadByEntry.contains(pane), "the quick click read the tab without the flash")
        try await PinnedPageTests.until({ !unread.showsUnread }, report: { "the quick click left the tab's blue dot" })
    }

    /// https://github.com/manaflow-ai/cmux/issues/56125: b shows once with nothing to ring, is parked, and its pane rings
    /// while parked (a parked workspace follows no marks, so its chrome never took this ring). Shown again
    /// with nothing looking at it, the pane shows its ring once the switch's frame lets rings draw, and keeps it.
    @Test func aPaneThatRangWhileItsWorkspaceWasParkedShowsItsRingUntilAttended() async throws {
        let (fixture, model, overlay, pane) = try await Self.ringWhileParked()
        defer { fixture.close() }

        fixture.controller.showWorkspace(requested: fixture.b.id)
        #expect(fixture.controller.content?.layoutModel === model, "b did not come back from its parked content")
        #expect(model.attention[pane] != nil, "b's ring was read though nothing looks at it")
        try await PinnedPageTests.until({ !model.holdsAttentionUntilShown }, report: { "the hold never ended" })
        try await PinnedPageTests.until({ overlay.attentionRingShown && !overlay.attentionLayer.isHidden },
                                        report: { "the pane that rang while b was parked never drew its ring" })
        for _ in 0..<5 { await Task.yield() }
        #expect(overlay.attentionRingShown && !overlay.attentionLayer.isHidden && model.attention[pane] != nil,
                "the ring went though nothing attended the pane")
    }

    /// https://github.com/manaflow-ai/cmux/issues/56125, with cmux active: the switch is the person going into b's pane,
    /// so it reads the ring, and the ring shows as its dismiss blink once the switch's frame lets it draw. Before, the
    /// hold kept the chrome's parked rings, which never had this one: the switch read a ring that never drew at all.
    @Test func switchingToAWorkspaceWhosePaneRangWhileParkedStillBlinksItsRing() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (fixture, model, overlay, pane) = try await Self.ringWhileParked()
        defer { fixture.close() }
        fixture.services.appActiveSource = { true }

        fixture.controller.showWorkspace(requested: fixture.b.id)
        #expect(fixture.controller.content?.layoutModel === model, "b did not come back from its parked content")
        #expect(model.attention[pane] == nil && model.attentionReadByEntry.contains(pane), "the switch did not read b's ring")
        #expect(overlay.attentionLayer.isHidden, "the read ring blinks over the old workspace's frame")
        try await PinnedPageTests.until({ !model.holdsAttentionUntilShown }, report: { "the hold never ended" })
        try await PinnedPageTests.until({ overlay.attentionAnimationKeys.contains("attention-dismiss") },
                                        report: { "the ring b's pane got while parked never showed: no dismiss blink on the overlay" })
        #expect(!overlay.attentionLayer.isHidden, "the blink plays hidden")
    }

    /// Shows b (no ring yet), parks it behind a, then gives b's pane an unread notification while cmux is in the back.
    private static func ringWhileParked() async throws -> (Fixture, LayoutModel, PaneOverlayView, LayoutPaneID) {
        let fixture = try await Self.open(active: false, bRings: false)
        let pane = LayoutPaneID(fixture.ringing.id)
        fixture.controller.showWorkspace(requested: fixture.b.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.b && fixture.controller.content?.layoutModel.focusedPane == pane },
                                        report: { "workspace b never showed with its pane focused" })
        let model = try #require(fixture.controller.content?.layoutModel)
        let overlay = try #require(fixture.controller.content?.layoutView.context.hosts[pane]?.chrome, "b's pane has no overlay")
        #expect(model.attention[pane] == nil && !overlay.attentionRingShown, "b rang before its notification came")
        fixture.controller.showWorkspace(requested: fixture.a.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.a && fixture.controller.focus.state.pane != fixture.ringing.id })
        #expect(fixture.controller.parked[fixture.b.id]?.layoutModel === model, "b was not kept parked")

        fixture.services.machines.local.store.apply(snapshot: Self.tree(bRings: true))
        let tab = try #require(fixture.b.screens.first?.panes.first?.tabs.first, "b's tab went with the new snapshot")
        try await PinnedPageTests.until({ tab.showsUnread }, report: { "b's tab never took its notification" })
        #expect(model.attention[pane] == nil && !overlay.attentionRingShown, "a parked workspace followed its marks")
        return (fixture, model, overlay, pane)
    }
}
