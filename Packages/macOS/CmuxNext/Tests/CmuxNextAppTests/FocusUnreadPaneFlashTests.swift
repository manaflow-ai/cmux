import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextBridge
import CmuxNextDesign
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/42210: focusing a pane whose terminal finished (an
/// unread notification rings it) blinks the ring out, as cmux classic's dismiss flash did on focus.
/// The `focus` dismissal took the ring away the moment the pane became the viewed one, before (or
/// without) any entry read, so the ring only faded.
@MainActor
@Suite(.serialized)
struct FocusUnreadPaneFlashTests {
    /// One workspace, two panes side by side; only `unreadPane`'s tab holds an unread notification.
    private static func tree() -> DaemonTree {
        let marker = TabNotification(notification: NotificationID(rawValue: 9), unread: true, level: .info, source: "terminal")
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~", notification: marker)])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "focus-flash-ws"), name: "focus", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "focus-flash-ws"), index: 0)])
        return tree
    }

    private struct Fixture {
        let services: AppServices
        let controller: WindowController
        let window: NSWindow
        let content: WorkspaceContentController
        let quiet: PaneModel
        let unread: PaneModel
    }

    private static func open() async throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), keyWindowSource: { nil }, appActiveSource: { true },
                                   heldKeyReplay: { event, _, _ in NSApp?.sendEvent(event) })
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["focus-flash-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        let window = try #require(controller.window)
        try await PinnedPageTests.until({ controller.workspaceContent?.panes.count == 2 && controller.focus.state.pane != nil })
        let content = try #require(controller.workspaceContent)
        let panes = try #require(store.workspaces.first?.screens.first?.panes)
        let unread = try #require(panes.first { $0.tabs.first?.hasUnread == true })
        let quiet = try #require(panes.first { $0 !== unread })
        // Start in the quiet pane, the window key: the unread pane rings.
        content.layoutModel.focus(LayoutPaneID(quiet.id), source: .keyboard)
        controller.focus.send(.windowKey(true))
        try await PinnedPageTests.until({ controller.focus.state.windowKey && controller.focus.state.pane == quiet.id })
        try await PinnedPageTests.until({ content.layoutModel.attention[LayoutPaneID(unread.id)] != nil },
                                        report: { "the unread pane never rang" })
        return Fixture(services: services, controller: controller, window: window, content: content, quiet: quiet, unread: unread)
    }

    @Test func focusingAFinishedTerminalBlinksItsRingOut() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let pane = LayoutPaneID(fixture.unread.id)
        fixture.content.layoutModel.focus(pane, source: .keyboard)
        try await PinnedPageTests.until({ fixture.content.layoutModel.attention[pane] == nil },
                                        report: { "focusing the pane left its ring" })
        #expect(fixture.content.layoutModel.attentionReadByEntry.contains(pane),
                "focusing the finished terminal took its ring away without the dismiss flash")
        #expect(fixture.unread.tabs.first?.hasUnread == false, "focusing the pane did not read its notification")
    }

    /// `notifications.attention.flash` off: focusing still reads the pane, with no flash.
    @Test func theFlashSettingTurnsTheFocusBlinkOff() async throws {
        let design = DesignSettings.shared
        let before = design.attention
        defer { design.attention = before }
        design.attention.flashesOnRead = false
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let pane = LayoutPaneID(fixture.unread.id)
        fixture.content.layoutModel.focus(pane, source: .keyboard)
        try await PinnedPageTests.until({ fixture.content.layoutModel.attention[pane] == nil })
        #expect(!fixture.content.layoutModel.attentionReadByEntry.contains(pane), "the focus blinked with the flash off")
    }

    /// The stuck ring in cmux#42210's follow-up: an agent chat's Chromium page is a child window
    /// that takes the key from the cmux window (`windowKey` false). The pane it shows is still the
    /// one looked at, so focusing it reads its notification and its ring goes.
    @Test func aPageWindowHoldingTheKeyStillReadsTheFocusedPane() async throws {
        let fixture = try await Self.open()
        let page = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        defer {
            fixture.window.removeChildWindow(page)
            page.close()
            fixture.controller.teardown()
            fixture.window.close()
        }
        fixture.window.addChildWindow(page, ordered: .above)
        fixture.services.keyWindowSource = { page }
        fixture.controller.focus.send(.windowKey(false))
        try await PinnedPageTests.until({ !fixture.controller.focus.state.windowKey })
        let pane = LayoutPaneID(fixture.unread.id)
        fixture.content.layoutModel.focus(pane, source: .keyboard)
        try await PinnedPageTests.until({ fixture.unread.tabs.first?.hasUnread == false && fixture.content.layoutModel.attention[pane] == nil },
                                        report: { "the pane under a key page window kept its ring" })
    }
}
