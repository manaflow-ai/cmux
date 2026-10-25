import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-10-21: "the animation for opening up a new tab starts off in the left pane, and it doesn't
/// start off at the right". A link opened to the side is made unselected in the pane it was opened
/// from, then moved into a split on its right (``LinkOpener``), or kept there while the lone chat it
/// shares the pane with docks left (``MainPaneLayout``). Its open must start where it lands: no step of
/// that round trip lists it in the left pane's strip, so the first strip that shows it, where its tab
/// opens, is the one on the right (``OutboundTab``).
@MainActor @Suite(.serialized) struct SideOpenStripTests {
    private static let left = PaneID(rawValue: 1), right = PaneID(rawValue: 2)
    private static let home = SurfaceID(rawValue: 1), link = SurfaceID(rawValue: 2)

    /// One screen: the left pane with `surfaces`, and with `moved` a pane split off on its right holding those.
    /// `ids` names a surface's tab by a resource id (an agent tab's), else the tab is the surface's.
    private static func tree(left surfaces: [SurfaceID], right moved: [SurfaceID] = [], ids: [SurfaceID: String] = [:]) -> DaemonTree {
        func pane(_ id: PaneID, _ surfaces: [SurfaceID]) -> PaneSnapshot {
            PaneSnapshot(id: id, tabs: surfaces.map { TabSnapshot(surface: $0, tabResourceID: ids[$0].map(ResourceID.init(rawValue:)), title: "~") })
        }
        var panes = [pane(left, surfaces)], layout = LayoutNode.leaf(left)
        if !moved.isEmpty {
            panes.append(pane(right, moved))
            layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(left), b: .leaf(right))
        }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: panes)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    /// The left pane, with one terminal and nothing on its right.
    /// A pane holds its window state weakly (its window owns it): the caller keeps the returned state
    /// alive for the test, or the pane selects nothing.
    private static func pane() throws -> (AppServices, PaneController, WindowState) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.daemon.store.apply(snapshot: tree(left: [home]))
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: state)
        return (services, pane, state)
    }

    /// The surfaces `pane`'s strip lists once it took the store's tabs.
    private static func listed(_ pane: PaneController) -> [SurfaceID] {
        pane.syncStripFromStore()
        return pane.stripModel.tabs.compactMap { item in pane.pane.tabs.first { $0.id == item.id.rawValue }?.surface }
    }

    @Test func aLinkOpenedToTheRightNeverShowsInTheLeftPanesStrip() throws {
        let (services, pane, state) = try Self.pane()
        defer { withExtendedLifetime(state) { pane.teardown() } }
        services.linkOpener.placement = { .splitRight }
        var placed: (@MainActor (SurfaceID) -> Void)?
        let opened = services.linkOpener.open(from: pane) { _, then in
            placed = then
            return true
        }
        #expect(opened)
        // The daemon's echo lists the new tab in the left pane before its answer names it.
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home, Self.link]))
        #expect(Self.listed(pane) == [Self.home], "the new tab opened in the left pane's strip before its answer")
        let then = try #require(placed)
        then(Self.link)
        #expect(Self.listed(pane) == [Self.home], "the new tab opened in the left pane's strip on its way right")
        // The move lands: the tab is in the pane on the right, the first strip that lists it.
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home], right: [Self.link]))
        #expect(Self.listed(pane) == [Self.home])
        #expect(services.daemon.store.workspaces.first?.screens.first?.panes.first { $0.handle == Self.right }?.tabs.map(\.surface) == [Self.link])
    }

    /// A lone chat's link (Leo: "it plays the opening animation on the main window and then opens the
    /// tab on the right split"): the tab stays in the chat's pane, which becomes the column right of
    /// the chat's new dock. While the chat is still there the strip leaves the tab out; once the chat
    /// left, the pane (now on the right) lists it, and its open plays there.
    @Test func aLoneChatsLinkShowsOnlyOnceTheChatLeftItsPane() throws {
        let (services, pane, state) = try Self.pane()
        defer { withExtendedLifetime(state) { pane.teardown() } }
        let outbound = OutboundTab.begin(in: pane)
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home, Self.link]))
        outbound.made(Self.link)
        let chat = try #require(pane.pane.tabs.first { $0.surface == Self.home })
        outbound.hidden(whileHolding: chat.id)
        #expect(Self.listed(pane) == [Self.home], "the link's tab opened over the lone chat")
        // The chat docks: it leaves for a pane of its own and the tab stays.
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.link], right: [Self.home]))
        #expect(Self.listed(pane) == [Self.link], "the tab did not show once the chat left")
        outbound.finish(moved: true)
        #expect(Self.listed(pane) == [Self.link])
    }

    /// A move that failed (or an open that never named its tab) lists the tab where it is at once, so
    /// it never stays hidden; until then it stays out.
    @Test func aFailedMoveShowsTheTabInItsPane() throws {
        let (services, pane, state) = try Self.pane()
        defer { withExtendedLifetime(state) { pane.teardown() } }
        let outbound = OutboundTab.begin(in: pane)
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home, Self.link]))
        #expect(Self.listed(pane) == [Self.home])
        outbound.made(Self.link)
        #expect(Self.listed(pane) == [Self.home])
        outbound.finish(moved: false)
        #expect(Self.listed(pane) == [Self.home, Self.link], "a tab whose move failed stayed hidden")
        #expect(OutboundTab.hidden(in: pane).isEmpty)
    }

    /// A file or page opened to the side shows a stand-in tab in its pane at once (an unselected
    /// provisional tab, until the daemon's tab replaces it): it stays out of the left strip too, before
    /// and after the open names the daemon's tab.
    @Test func theOpensOwnStandInNeverShowsInTheLeftPanesStrip() throws {
        let (services, pane, state) = try Self.pane()
        defer { withExtendedLifetime(state) { pane.teardown() } }
        services.linkOpener.placement = { .splitRight }
        let standIn = ProvisionalTab()
        var placed: (@MainActor (SurfaceID) -> Void)?
        let opened = services.linkOpener.open(from: pane) { target, then in
            services.daemon.store.intend(.createTab(pane: target.pane.handle, provisional:
                TabSnapshot(surface: standIn.surface, tabResourceID: ResourceID(rawValue: standIn.id), title: "page")),
                                         transaction: .generate())
            placed = then
            return true
        }
        #expect(opened)
        #expect(pane.pane.tabs.contains { $0.id == standIn.id }, "the stand-in is not in the pane")
        #expect(Self.listed(pane) == [Self.home], "the open's stand-in showed in the left pane's strip")
        let then = try #require(placed)
        then(Self.link)
        #expect(Self.listed(pane) == [Self.home], "the open's stand-in showed in the left pane's strip once named")
    }

    /// Codex on #23969: a tab the pane selects mid-move (a person's click, or a selection the pane waits
    /// for) shows, and stays listed when the move later lands, so selection and Cmd-W never point at a
    /// tab the strip leaves out.
    @Test func aTabThePaneSelectsMidMoveStaysListed() throws {
        let (services, pane, state) = try Self.pane()
        defer { withExtendedLifetime(state) { pane.teardown() } }
        let outbound = OutboundTab.begin(in: pane)
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home, Self.link]))
        outbound.made(Self.link)
        #expect(Self.listed(pane) == [Self.home])
        pane.selectWhenReportedKeepingFocus(surface: Self.link)
        #expect(Self.listed(pane) == [Self.home, Self.link], "the tab the pane selected stayed out of its strip")
        let link = try #require(pane.pane.tabs.first { $0.surface == Self.link })
        #expect(pane.stripModel.selectedID?.rawValue == link.id)
        outbound.finish(moved: true)
        #expect(Self.listed(pane) == [Self.home, Self.link], "a selected tab was hidden again when its move landed")
    }

    /// Codex on #23969: the move can land before the source pane's tabs drop the tab. The hold lasts
    /// until they do (not a fixed delay), then ends, so the tab never comes back into the left strip.
    @Test func aLandedMoveHoldsTheTabUntilTheSourcePaneDropsIt() throws {
        let (services, pane, state) = try Self.pane()
        defer { withExtendedLifetime(state) { pane.teardown() } }
        let outbound = OutboundTab.begin(in: pane)
        outbound.made(Self.link)
        // The move answers before the source pane's tabs ever listed the tab: the hold waits for it.
        outbound.finish(moved: true)
        #expect(Self.listed(pane) == [Self.home])
        #expect(OutboundTab.count(in: pane) == 1, "a landed move let go before its tab was ever listed")
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home, Self.link]))
        #expect(Self.listed(pane) == [Self.home], "the tab came back into the left strip before its pane dropped it")
        #expect(OutboundTab.count(in: pane) == 1)
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home], right: [Self.link]))
        #expect(Self.listed(pane) == [Self.home])
        #expect(OutboundTab.count(in: pane) == 0, "the hold outlived the tab's departure")
    }

    /// An open refused at once, or a move cancelled before it named its tab, holds nothing.
    @Test func aRefusedOrCancelledOpenHoldsNothing() throws {
        let (services, pane, state) = try Self.pane()
        defer { withExtendedLifetime(state) { pane.teardown() } }
        #expect(!OutboundTab.begin(in: pane).started(false))
        let cancelled = OutboundTab.begin(in: pane)
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home, Self.link]))
        #expect(Self.listed(pane) == [Self.home])
        cancelled.finish(moved: false)
        #expect(Self.listed(pane) == [Self.home, Self.link], "a cancelled open left the pane's new tab hidden")
        #expect(OutboundTab.count(in: pane) == 0)
    }

    /// Codex on #23969: a hold names an agent tab by id. Once the pane dropped that id, or lists it
    /// under another surface, it is another tab (an id reused) and shows.
    @Test func anIdReusedWhileHeldShows() throws {
        let (services, pane, state) = try Self.pane()
        defer { withExtendedLifetime(state) { pane.teardown() } }
        let reused = SurfaceID(rawValue: 3), id = "tab_agent"
        let outbound = OutboundTab.begin(in: pane)
        outbound.made(key: id)
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home, Self.link], ids: [Self.link: id]))
        #expect(Self.listed(pane) == [Self.home])
        // The same id under another surface while the hold lasts.
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home, reused], ids: [reused: id]))
        #expect(Self.listed(pane) == [Self.home, reused], "a reused id was hidden as the outbound tab")
        // Back under its first surface without leaving the pane: still the reused tab, never held again.
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home, Self.link], ids: [Self.link: id]))
        #expect(Self.listed(pane) == [Self.home, Self.link], "a reused id was held again under its first surface")
        // Dropped, then listed again under its first surface: still another tab.
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home]))
        _ = Self.listed(pane)
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home, Self.link], ids: [Self.link: id]))
        #expect(Self.listed(pane) == [Self.home, Self.link], "an id the pane dropped was held again")
        outbound.finish(moved: false)
    }
}
