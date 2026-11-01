@testable import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// FC-1 follow-up (fuzz catalog, 2026-11-01): Home's dock is pinned in its dock move and lets other tabs in only by a
/// later `column.update {allow_tabs: true}` (``HomeDock``'s allow-tabs step). That step needs the dock's screen and
/// pane resource ids. When the tree had none yet, the step returned "waits for resource ids" and nothing ran it again
/// until the next connection: the dock took no tab for the whole launch, so every new tab aimed at it was refused
/// (`dock-column-pinned`). Once the tree reports the ids, the step must run, with no timer and no new connect.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct HomeDockAllowTabsTests {
    private static let pane = PaneID(rawValue: 1)
    private static let workspaceResource = ResourceID(rawValue: "ws_home")
    private static let screenResource = ResourceID(rawValue: "scr_home")
    private static let paneResource = ResourceID(rawValue: "pane_home")

    /// The home workspace with its page tab in a pinned left chat dock that takes no tabs; with the screen and pane
    /// resource ids only when `identified`.
    private static func tree(identified: Bool) -> DaemonTree {
        var page = TabSnapshot(surface: SurfaceID(rawValue: 2), kind: .conversation)
        page.conversation = ConversationTabRef(page: WorkspaceModel.homeDockPage)
        let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true, allowsTabs: false)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 3), resourceID: identified ? screenResource : nil, active: true,
                                    activePane: pane, layout: .leaf(pane),
                                    columns: [ColumnSnapshot(id: 10, width: 0.3, layout: .leaf(pane), dock: dock)],
                                    panes: [PaneSnapshot(id: pane, resourceID: identified ? paneResource : nil, tabs: [page])])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 4), key: nil, resourceID: workspaceResource,
                                                         name: "Home", screens: [screen])])
    }

    /// The requests the step sent, read without awaiting it.
    @MainActor final class Sent {
        var requests: [(screen: ResourceID, pane: ResourceID)] = []
    }

    @Test func theDockTakesTabsOnceTheTreeReportsItsIDs() async throws {
        let store = DaemonStore()
        store.noteHandshake(DaemonIdentity(capabilities: [DaemonCapability.pinnedDock.rawValue], generation: "home-dock-allow-tabs"))
        store.apply(snapshot: Self.tree(identified: false))
        let defaults = try #require(UserDefaults(suiteName: "home-dock-allow-tabs-\(UUID().uuidString)"))
        let dock = HomeDock(defaults: defaults)
        let sent = Sent()
        let workspace: @MainActor @Sendable () -> WorkspaceModel? = { store.workspaces.first { $0.resourceID == Self.workspaceResource } }
        let step = await dock.allowTabsLogged(store: store, workspace: workspace, fresh: true) { screen, pane in
            await MainActor.run { sent.requests.append((screen, pane)) }
        }
        #expect(step == "home dock allow_tabs waits for resource ids", "the step: \(String(describing: step))")
        #expect(sent.requests.isEmpty, "allow_tabs was sent with no ids")

        // The tree reports the ids (the next snapshot): the step runs now, once, for the dock's screen and pane.
        store.apply(snapshot: Self.tree(identified: true))
        // Bounded by the suite's time limit; a step that never runs fails the expectations below once 2000 hops passed.
        for _ in 0..<2000 where sent.requests.isEmpty { await Task.yield() }
        #expect(sent.requests.map(\.screen) == [Self.screenResource], "allow_tabs did not run once the ids came: \(sent.requests)")
        #expect(sent.requests.map(\.pane) == [Self.paneResource])
        #expect(defaults.bool(forKey: HomeDock.dockTakesTabsKey), "the dock was not recorded as taking tabs")
    }
}
