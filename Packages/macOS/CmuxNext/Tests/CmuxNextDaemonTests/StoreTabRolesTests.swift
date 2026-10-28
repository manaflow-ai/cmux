import CmuxNextCompat
import Foundation
import Observation
import Testing
@testable import CmuxNextDaemon

/// Set once from an observation's change callback (called synchronously inside the mutation).
private final class RolesChanged: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

/// The store's agent chat and browser tabs (`StoreTabRoles`) stay what a walk of the tree finds, as tabs come, go,
/// move and change, and their revisions move only for a change of a role: a terminal's change, a re-key or a resync
/// of the same tree moves neither, so a reader of the roles is not re-run by the rest of the session.
@MainActor @Suite struct StoreTabRolesTests {
    static func chat(_ surface: UInt64, session: String?) -> TabSnapshot {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "chat")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:here", session: session))
        return tab
    }

    static func browser(_ surface: UInt64, url: String, favicon: String? = nil) -> TabSnapshot {
        TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .browser, title: "page", url: url, faviconURL: favicon)
    }

    static func terminal(_ surface: UInt64, title: String = "zsh") -> TabSnapshot {
        TabSnapshot(surface: SurfaceID(rawValue: surface), title: title)
    }

    /// Workspace w (handle w) has screen w*10 with pane w*100 holding `tabs[w-1]`.
    static func tree(_ tabs: [[TabSnapshot]]) -> DaemonTree {
        DaemonTree(workspaces: tabs.enumerated().map { index, tabs in
            let w = UInt64(index + 1)
            let pane = PaneID(rawValue: w * 100)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: w * 10), layout: .leaf(pane), panes: [PaneSnapshot(id: pane, tabs: tabs)])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: w), key: WorkspaceKey(rawValue: "w\(w)"), name: "w\(w)", screens: [screen])
        })
    }

    static func walk(_ store: DaemonStore) -> [TabModel] {
        store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
    }

    /// What a walk of the tree finds, as the roles list it.
    static func expectMatchesWalk(_ store: DaemonStore, sourceLocation: SourceLocation = #_sourceLocation) {
        let tabs = walk(store)
        #expect(store.tabRoles.chatTabs.map(\.id) == tabs.filter { $0.agentSession != nil }.map(\.id).sorted(), sourceLocation: sourceLocation)
        #expect(store.tabRoles.browserTabs.map(\.id) == tabs.filter { $0.kind == .browser }.map(\.id).sorted(), sourceLocation: sourceLocation)
        #expect(store.tabRoles.chatTabs(showing: nil).map(\.id)
                    == tabs.filter { $0.agentSession != nil && $0.agentSession?.session == nil }.map(\.id).sorted(), sourceLocation: sourceLocation)
    }

    static func observing(_ read: () -> Void) -> RolesChanged {
        let changed = RolesChanged()
        withObservationTracking(read) { changed.set() }
        return changed
    }

    @Test func theRolesListWhatAWalkFindsAsTabsComeGoAndChange() {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree([[Self.terminal(1), Self.chat(2, session: "s-a"), Self.chat(3, session: nil)],
                                         [Self.browser(4, url: "https://a.example/x", favicon: "https://a.example/i.png"), Self.terminal(5)]]))
        Self.expectMatchesWalk(store)
        #expect(store.tabRoles.chatTabs(showing: "s-a").map(\.surface) == [2])
        // A tab added, one closed, one moved to the other workspace.
        store.apply(.tabAdded(TabDelta(workspace: 2, screen: 20, pane: 200, surface: 6, index: nil, entity: Self.chat(6, session: "s-b"))))
        store.apply(.tabClosed(TabDelta(workspace: 1, screen: 10, pane: 100, surface: 3, index: nil, entity: Self.chat(3, session: nil))))
        store.apply(.tabChanged(TabDelta(workspace: 2, screen: 20, pane: 200, surface: 2, index: nil, entity: Self.chat(2, session: "s-a"))))
        Self.expectMatchesWalk(store)
        #expect(store.tabRoles.chatTabs(showing: "s-a").count == 1, "a moved chat is listed once")
        // A blank chat gets its session; a browser navigates; a terminal's kind does not change its role.
        store.apply(.tabChanged(TabDelta(workspace: 2, screen: 20, pane: 200, surface: 6, index: nil, entity: Self.chat(6, session: "s-c"))))
        store.apply(.tabChanged(TabDelta(workspace: 2, screen: 20, pane: 200, surface: 4, index: nil,
                                         entity: Self.browser(4, url: "https://b.example/", favicon: nil))))
        Self.expectMatchesWalk(store)
        #expect(store.tabRoles.chatTabs(showing: "s-b").isEmpty && store.tabRoles.chatTabs(showing: "s-c").count == 1)
        #expect(store.tabRoles.browserTabs.first?.url == "https://b.example/")
        // A resync to a different tree.
        store.apply(snapshot: Self.tree([[Self.terminal(1)], [Self.browser(7, url: "https://c.example/")]]))
        Self.expectMatchesWalk(store)
        #expect(store.tabRoles.counts == (chats: 0, browsers: 1))
    }

    @Test func aTerminalChangeOrAResyncOfTheSameTreeMovesNoRevision() {
        let store = DaemonStore()
        let tree = Self.tree([[Self.terminal(1), Self.chat(2, session: "s-a")], [Self.browser(3, url: "https://a.example/")]])
        store.apply(snapshot: tree)
        let (chats, browsers) = (store.tabRoles.chatRevision, store.tabRoles.browserRevision)
        let changed = Self.observing { _ = store.tabRoles.chatTabs; _ = store.tabRoles.browserTabs }
        // A terminal opens, retitles and closes; the same tree comes again (a resync).
        store.apply(.tabAdded(TabDelta(workspace: 1, screen: 10, pane: 100, surface: 9, index: nil, entity: Self.terminal(9))))
        store.apply(.tabChanged(TabDelta(workspace: 1, screen: 10, pane: 100, surface: 1, index: nil, entity: Self.terminal(1, title: "vim"))))
        store.apply(.tabClosed(TabDelta(workspace: 1, screen: 10, pane: 100, surface: 9, index: nil, entity: Self.terminal(9))))
        store.apply(snapshot: tree)
        #expect(store.tabRoles.chatRevision == chats && store.tabRoles.browserRevision == browsers)
        #expect(!changed.isSet, "a terminal's change or a resync of the same tree re-ran a reader of the roles")
        // A chat's session changes: the chat revision moves, once.
        store.apply(.tabChanged(TabDelta(workspace: 1, screen: 10, pane: 100, surface: 2, index: nil, entity: Self.chat(2, session: "s-b"))))
        #expect(store.tabRoles.chatRevision == chats &+ 1 && store.tabRoles.browserRevision == browsers)
        #expect(changed.isSet)
    }

    @Test func aFollowerHearsEachChangedBrowserOnce() {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree([[Self.browser(1, url: "https://a.example/"), Self.terminal(2)]]))
        final class Heard { var changes: [[StoreTabRoles.BrowserChange]] = [] }
        let heard = Heard()
        store.tabRoles.followBrowsers(heard) { heard.changes.append($0) }
        store.apply(.tabChanged(TabDelta(workspace: 1, screen: 10, pane: 100, surface: 2, index: nil, entity: Self.terminal(2, title: "top"))))
        #expect(heard.changes.isEmpty, "a terminal's change told the browser follower")
        store.apply(.tabChanged(TabDelta(workspace: 1, screen: 10, pane: 100, surface: 1, index: nil,
                                         entity: Self.browser(1, url: "https://a.example/", favicon: "https://a.example/f.ico"))))
        #expect(heard.changes.count == 1 && heard.changes.last?.first?.tab?.faviconURL == "https://a.example/f.ico")
        store.apply(.tabClosed(TabDelta(workspace: 1, screen: 10, pane: 100, surface: 1, index: nil, entity: Self.browser(1, url: "https://a.example/"))))
        #expect(heard.changes.count == 2 && heard.changes.last?.count == 1 && heard.changes.last?.first?.tab == nil)
        store.tabRoles.stopFollowingBrowsers(heard)
    }
}
