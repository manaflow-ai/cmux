@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// A banner clicked after cmux quit and launched again opens its tab (audit 4, P1). macOS hands the click
/// to the delegate the app set before it finished launching, which is before the app's services exist and
/// before the daemon's tree arrives; and a relaunch can give the tab a new surface handle. So the banner
/// names its tab by the tab's lasting id, a click that comes early waits for the services, and a click
/// whose tab is not in the tree yet waits (bounded) for it to arrive.
@MainActor @Suite(.timeLimit(.minutes(1))) struct BannerClickAfterRelaunchTests {
    /// A tree with tab `tab_a` on `surface` (and a terminal on surface 1 when `surface` is not 1).
    private func tree(tabA surface: UInt64) -> DaemonTree {
        var tabs = [TabSnapshot(surface: SurfaceID(rawValue: surface), tabResourceID: ResourceID(rawValue: "tab_a"), name: "Claude Code",
                                notification: TabNotification(notification: NotificationID(rawValue: 5), unread: true, source: "agent"))]
        if surface != 1 { tabs.append(TabSnapshot(surface: 1, tabResourceID: ResourceID(rawValue: "tab_other"), name: "zsh")) }
        let pane = PaneSnapshot(id: 1, tabs: tabs)
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "api-server", screens: [screen])])
    }

    @Test func aBannerNamesItsTabByTheTabsLastingID() throws {
        let store = DaemonStore()
        store.apply(snapshot: tree(tabA: 1))
        let workspace = try #require(store.workspaces.first)
        let pane = try #require(workspace.screens.first?.panes.first)
        let located = LocatedTab(tab: try #require(pane.tabs.first), pane: pane, workspace: workspace)
        let wire = #"{"notification":5,"title":"Claude finished","body":"","level":"info","surface":1,"source":"agent"}"#
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        let service = NotificationCenterService()
        service.screenLocked = { false }
        var decision = NotificationPolicy.Decision()
        decision.desktop = true
        service.deliver(notification, source: .agent, located: located, decision: decision, program: nil)
        let posted = try #require(service.desktop.posted.last)
        #expect(posted.tab == "tab_a")
        #expect(posted.surface == 1)
    }

    /// A tab with no `tab_` resource id has a `surface:N` id, which a relaunch can give to another tab:
    /// its banner names no lasting id and keeps its surface handle, as before.
    @Test func aTabWithoutAResourceIDNamesNoLastingID() throws {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, name: "zsh")])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w",
                                                                        screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])])]))
        let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let wire = #"{"notification":5,"title":"t","body":"","level":"info","surface":1,"source":"terminal"}"#
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        #expect(NotificationCenterService.bannerTabID(notification, tab: tab, owner: tab) == nil)
    }

    /// The click macOS delivers at launch, before `NotificationCenterService.start` wired the handlers.
    @Test func aClickBeforeTheHandlersAreWiredRunsWhenTheyAre() {
        let desktop = NotificationCenterService().desktop
        desktop.received(DesktopNotifier.BannerResponse(id: "cmux-notification-5", surface: 1, tab: nil, action: .open))
        var opened: [String] = []
        desktop.onOpen = { id, _ in opened.append(id) }
        #expect(opened.isEmpty)
        desktop.handlersWired()
        #expect(opened == ["cmux-notification-5"])
        // Wired: a later click runs at once, and the early one never runs twice.
        desktop.received(DesktopNotifier.BannerResponse(id: "cmux-notification-6", surface: 1, tab: nil, action: .open))
        #expect(opened == ["cmux-notification-5", "cmux-notification-6"])
    }

    /// After a relaunch the tab is on surface 9 and surface 1 is another tab: the click opens the banner's tab.
    @Test func aClickFindsItsTabByIDNotByItsOldSurface() {
        let frames = NotificationFrames()
        let service = frames.service()
        let store = DaemonStore()
        store.apply(snapshot: tree(tabA: 9))
        let found = Found()
        service.whenBannerTab("tab_a", in: store) { found.values.append($0) }
        #expect(found.values == [9])
    }

    /// The click came before the daemon's tree: it waits for the tab, then names its surface.
    @Test func aClickWaitsForItsTabToArrive() {
        let frames = NotificationFrames()
        let service = frames.service()
        let store = DaemonStore()
        let found = Found()
        service.whenBannerTab("tab_a", in: store) { found.values.append($0) }
        frames.frame()
        #expect(found.values.isEmpty)
        store.apply(snapshot: tree(tabA: 9))
        frames.frame()
        #expect(found.values == [9])
        frames.advance(by: NotificationCenterService.bannerTabWait + .seconds(1))
        #expect(found.values == [9], "the wait ends once")
    }

    /// A tab that never comes back (closed while cmux was not running) opens nothing, and the wait ends.
    @Test func aClickWhoseTabNeverArrivesGivesUp() {
        let frames = NotificationFrames()
        let service = frames.service()
        let store = DaemonStore()
        let found = Found()
        service.whenBannerTab("tab_a", in: store) { found.values.append($0) }
        frames.advance(by: NotificationCenterService.bannerTabWait + .seconds(1))
        #expect(found.values == [nil])
        store.apply(snapshot: tree(tabA: 9))
        frames.frame()
        #expect(found.values == [nil], "a tab that comes after the wait is not opened")
    }
}

/// What a banner tab wait handed its caller, in order.
@MainActor private final class Found {
    var values: [UInt64?] = []
}
