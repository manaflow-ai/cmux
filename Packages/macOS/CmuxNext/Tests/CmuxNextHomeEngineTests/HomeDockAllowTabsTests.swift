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

    /// The requests the step sent; ``next()`` returns once one more came (no polling, no clock).
    @MainActor final class Sent {
        var requests: [(screen: ResourceID, pane: ResourceID)] = []
        private var waiter: CheckedContinuation<Void, Never>?

        func record(_ screen: ResourceID, _ pane: ResourceID) {
            requests.append((screen, pane))
            waiter?.resume()
            waiter = nil
        }

        /// Returns when the request count passes `count`; the suite's time limit bounds a request that never comes.
        func next(after count: Int) async {
            while requests.count <= count {
                await withCheckedContinuation { waiter = $0 }
            }
        }
    }

    /// A store at `identified: false` with the pinned-dock capability, a dock on a fresh UserDefaults suite (removed by
    /// the returned cleanup), and the home workspace reader.
    private static func setUp() throws -> (DaemonStore, HomeDock, UserDefaults, () -> Void,
                                            @MainActor @Sendable () -> WorkspaceModel?) {
        let store = DaemonStore()
        store.noteHandshake(DaemonIdentity(capabilities: [DaemonCapability.pinnedDock.rawValue], generation: "home-dock-allow-tabs"))
        store.apply(snapshot: Self.tree(identified: false))
        let suite = "home-dock-allow-tabs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let workspace: @MainActor @Sendable () -> WorkspaceModel? = { store.workspaces.first { $0.resourceID == Self.workspaceResource } }
        return (store, HomeDock(defaults: defaults), defaults, { defaults.removePersistentDomain(forName: suite) }, workspace)
    }

    @Test func theDockTakesTabsOnceTheTreeReportsItsIDs() async throws {
        let (store, dock, defaults, cleanup, workspace) = try Self.setUp()
        defer { cleanup() }
        let sent = Sent()
        let step = await dock.allowTabsLogged(store: store, workspace: workspace, fresh: true) { screen, pane in
            await sent.record(screen, pane)
        }
        #expect(step == "home dock allow_tabs waits for resource ids", "the step: \(String(describing: step))")
        #expect(sent.requests.isEmpty, "allow_tabs was sent with no ids")

        // The tree reports the ids (the next snapshot): the step runs now, once, for the dock's screen and pane.
        store.apply(snapshot: Self.tree(identified: true))
        await sent.next(after: 0)
        await dock.allowTabsWait?.value
        #expect(sent.requests.map(\.screen) == [Self.screenResource], "allow_tabs did not run once the ids came: \(sent.requests)")
        #expect(sent.requests.map(\.pane) == [Self.paneResource])
        #expect(defaults.bool(forKey: HomeDock.dockTakesTabsKey), "the dock was not recorded as taking tabs")
    }

    /// A later step (a reconnect's) replaces the wait: when the ids come, one request goes, not one per step.
    @Test func aLaterStepReplacesTheWait() async throws {
        let (store, dock, _, cleanup, workspace) = try Self.setUp()
        defer { cleanup() }
        let sent = Sent()
        let allow: HomeDock.AllowTabs = { screen, pane in await sent.record(screen, pane) }
        _ = await dock.allowTabsLogged(store: store, workspace: workspace, fresh: true, allow: allow)
        let first = try #require(dock.allowTabsWait, "the first step armed no wait")
        _ = await dock.allowTabsLogged(store: store, workspace: workspace, fresh: true, allow: allow)
        let second = try #require(dock.allowTabsWait, "the second step armed no wait")
        await first.value // cancelled by the second step: it ends with no request
        #expect(sent.requests.isEmpty)

        store.apply(snapshot: Self.tree(identified: true))
        await sent.next(after: 0)
        await second.value
        #expect(sent.requests.count == 1, "one request per arrival of the ids, not one per step: \(sent.requests)")
    }

    /// Home's page gone (the workspace closed, a new Home made): the wait ends and sends nothing when ids come later.
    @Test func theWaitEndsWhenHomesPageIsGone() async throws {
        let (store, dock, _, cleanup, workspace) = try Self.setUp()
        defer { cleanup() }
        let sent = Sent()
        _ = await dock.allowTabsLogged(store: store, workspace: workspace, fresh: true) { screen, pane in
            await sent.record(screen, pane)
        }
        let wait = try #require(dock.allowTabsWait, "the step armed no wait")
        store.apply(snapshot: DaemonTree(workspaces: []))
        await wait.value // ended: the page is gone
        store.apply(snapshot: Self.tree(identified: true))
        #expect(dock.allowTabsWait == nil || dock.allowTabsWait == wait, "a new wait started with no step")
        #expect(sent.requests.isEmpty, "the ended wait sent allow_tabs: \(sent.requests)")
    }
}
