import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A session of a ``SessionFixtureSize`` as a store fixture in a whole window. `large` (the default) is the session of
/// plans/cmux-next/main-thread-scheduling.md 1.5: 60 workspaces x 6 tabs = 360 tabs; each workspace has one screen with
/// one pane of 3 terminals, 1 agent chat, 1 Chromium page and 1 WebKit page; the 5 agent terminals are the first
/// terminal of workspaces 1, 13, 25, 37 and 49. `real` is the person's session: 826 workspaces, 858 panes, 1600 tabs,
/// 798 terminals, 170 agent terminals (the mix rule is ``SessionFixtureSize/shape(_:)``). The window holds every
/// workspace and shows the last one, so every agent terminal is hidden.
///
/// ``withWindow(_:_:)`` opens a whole window through the app's real composition root (`AppServices`), so every observer
/// the app starts (sidebar, strip, link places, attention, favicons, the namer, ...) runs through its real init. Tests
/// count what a change wakes with `ObservationWakes`.
///
/// Not `LargeSessionFixture`: that name is the one shared store fixture of #40126 (MTS-4 O2), which the row tests use.
/// This one opens a whole window through `AppServices`, so it keeps its own name and any merge order compiles.
@MainActor
enum LargeSessionWindowFixture {
    /// The `large` arm's sizes, for a caller that runs at `large` only. A test that takes a size reads the size.
    static let workspaces = SessionFixtureSize.large.workspaces
    /// The stride of the surface ids at every size (the most tabs a workspace holds at `large`).
    static let tabsPerWorkspace = 6
    /// The surfaces of the `large` arm's 5 agent terminals, in 5 different hidden workspaces.
    static let agentSurfaces = agents(.large)
    /// A terminal of the `large` arm's shown workspace (60).
    static let shownTerminal = shown(.large)

    /// The surfaces of the size's agent terminals: all in hidden workspaces.
    static func agents(_ size: SessionFixtureSize) -> [SurfaceID] {
        size.places { $0 == .agentTerminal }.map { surface(workspace: $0.workspace, index: $0.index) }
    }

    /// The first terminal of the shown workspace (the last one).
    static func shown(_ size: SessionFixtureSize) -> SurfaceID { surface(workspace: size.workspaces, index: 0) }

    static func key(_ workspace: Int) -> String { "large-ws-\(workspace)" }

    static func surface(workspace: Int, index: Int) -> SurfaceID {
        SurfaceID(rawValue: UInt64((workspace - 1) * tabsPerWorkspace + index + 1))
    }

    private static func tab(_ kind: SessionFixtureSize.Tab, workspace: Int, index: Int) -> TabSnapshot {
        let id = surface(workspace: workspace, index: index)
        switch kind {
        case .chat:
            var chat = TabSnapshot(surface: id, kind: .conversation, title: "chat", browserRenderer: "frontend")
            chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", session: nil, harness: nil))
            return chat
        case .chromium:
            return TabSnapshot(surface: id, kind: .browser, url: "http://127.0.0.1:9/\(id.rawValue)", browserRenderer: "frontend", browserEngine: "cef")
        case .webkit:
            return TabSnapshot(surface: id, kind: .browser, url: "http://127.0.0.1:9/\(id.rawValue)", browserRenderer: "frontend", browserEngine: "webkit")
        case .terminal, .agentTerminal:
            return TabSnapshot(surface: id, title: "zsh")
        }
    }

    static func tree(_ size: SessionFixtureSize = .large) -> DaemonTree {
        let snapshots = (1...size.workspaces).map { workspace -> WorkspaceSnapshot in
            // `large` keeps its one pane of 6 tabs, as before the fixture took a size.
            let shape = size == .large ? [Array(size.shape(workspace).joined())] : size.shape(workspace)
            var panes: [PaneSnapshot] = []
            var index = 0
            for (offset, kinds) in shape.enumerated() {
                var tabs: [TabSnapshot] = []
                for kind in kinds {
                    tabs.append(tab(kind, workspace: workspace, index: index))
                    index += 1
                }
                // The first pane has the workspace's number; a second pane's id is past every first pane's.
                panes.append(PaneSnapshot(id: PaneID(rawValue: UInt64(offset * size.workspaces + workspace)), tabs: tabs))
            }
            var layout = LayoutNode.leaf(panes[0].id)
            if panes.count > 1 {
                layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(panes[0].id), b: .leaf(panes[1].id))
            }
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(workspace)), layout: layout, panes: panes)
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(workspace)), key: WorkspaceKey(rawValue: key(workspace)),
                                     name: "workspace \(workspace)", screens: [screen])
        }
        var tree = DaemonTree(registryID: "s-local", workspaces: snapshots)
        tree.personal = PersonalState(workspaces: (1...size.workspaces).map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key($0)), index: $0 - 1)
        })
        return tree
    }

    /// Lets the main actor run what is queued: a fixed number of yields, no wait for time to pass.
    static func drainMain() async {
        for _ in 0..<80 { await Task.yield() }
    }

    /// One `title-changed` line of the daemon, decoded as the connection decodes it. `text` and `activity` are the
    /// fields a daemon with D2 adds; a client that reads only `title` ignores them.
    static func titleChanged(_ surface: SurfaceID, raw: String, text: String, activity: String?) -> DaemonEvent {
        var line: [String: Any] = ["event": "title-changed", "surface": surface.rawValue, "title": raw, "text": text]
        line["activity"] = activity ?? NSNull()
        let data = (try? JSONSerialization.data(withJSONObject: line)) ?? Data()
        return DaemonEvent.decode(name: "title-changed", line: data)
    }

    /// Runs `body` on a whole window of the `large` session (its store), then closes it.
    static func withWindow<T>(_ body: @MainActor (DaemonStore) async throws -> T) async throws -> T {
        try await withWindow(.large, body)
    }

    /// Runs `body` on a whole window of a session of `size` (its store), then closes it.
    static func withWindow<T>(_ size: SessionFixtureSize, _ body: @MainActor (DaemonStore) async throws -> T) async throws -> T {
        try await withController(size) { store, _ in try await body(store) }
    }

    /// `withWindow(_:_:)` for a test that acts on the window: `body` also gets its controller (and so its `services`).
    static func withController<T>(_ size: SessionFixtureSize, _ body: @MainActor (DaemonStore, WindowController) async throws -> T) async throws -> T {
        try #require(size.mixFaults.isEmpty, "fixture: the \(size.rawValue) mix is wrong: \(size.mixFaults)")
        let workspaces = size.workspaces
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(size))
        let keys = [key(workspaces)] + (1..<workspaces).map(key)
        let controller = try #require(services.windows.openWindow(workspaces: keys, frame: CGRect(x: 200, y: 200, width: 1600, height: 900)))
        defer { controller.teardown(); controller.window?.close() }
        for _ in 0..<50 where controller.workspaceContent == nil { await drainMain() }
        let content = try #require(controller.workspaceContent)
        content.contentView.layoutSubtreeIfNeeded()
        await drainMain()
        try #require(store.workspaces.count == workspaces, "fixture: \(store.workspaces.count) workspaces, not \(workspaces)")
        return try await body(store, controller)
    }
}
